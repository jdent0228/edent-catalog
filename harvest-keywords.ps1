# 이덴트 숨은 검색키워드 하베스터
#
# [원리]
#  이덴트 검색창 자동완성(/program/searchResult.php)은 DB의 "검색 가능한 문자열"을
#  그대로 돌려준다 — 상품명·상품코드·규격·회사명 + 화면에 없는 관리자 입력 키워드.
#  (무의미한 문자열은 0건 → 검색로그가 아니라 실제 상품 데이터에서 나옴)
#  예) 'torpedo' 조회 → 'torpedoBUR' 반환. 이 문자열로 검색하면 pd_idx=13254 등이 나오는데,
#      13254의 화면 상품명은 'FG Pointed taper' 로 torpedo가 전혀 없다 = 숨은 키워드.
#
# [방법]
#  1) 우리 카탈로그의 상품명/규격에서 토큰(단어)을 뽑아 자동완성에 질의 → 후보 문자열 수집
#  2) 그중 우리가 이미 아는 값(상품명/코드/규격/회사명)과 일치하는 건 버림 → 남는 게 숨은 키워드
#  3) 각 키워드를 검색해서 어떤 상품에 붙은 것인지 확정 → keywords-map.json 에 캐시
#  캐시가 있으므로 다음 실행은 새 토큰/새 키워드만 처리한다(예산 제한).
#
# 사용법:  powershell -ExecutionPolicy Bypass -File harvest-keywords.ps1 -TokenBudget 300 -KeywordBudget 800

param(
  [int]$TokenBudget = 300,     # 이번 실행에서 처리할 토큰 수
  [int]$KeywordBudget = 800,   # 이번 실행에서 확정할 키워드 수
  [int]$MaxPages = 3,          # 토큰당 자동완성 페이지 수 (1페이지=20건)
  [int]$DelayMs = 600
)

$ErrorActionPreference = 'Stop'
$Base = 'https://www.edent.co.kr'
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$enc  = New-Object System.Text.UTF8Encoding($false)

function Get-Text([string]$url) {
  $r = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 30
  [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}
function Get-Auto([string]$q, [int]$page) {
  $b = "&param1=$([System.Uri]::EscapeDataString($q))&param2=5&param3=$page&param4=0&param5="
  $r = Invoke-WebRequest -Uri "$Base/program/searchResult.php" -Method Post -Body $b `
        -ContentType 'application/x-www-form-urlencoded' -UserAgent $ua -UseBasicParsing -TimeoutSec 30
  $c = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  $m = [regex]::Match($c, '\|:\|\|\|(\d+)\|:\|\|\|(\d+)\s*$')
  [pscustomobject]@{
    total = [int]$m.Groups[2].Value
    vals  = @([regex]::Matches($c, 's_rslt_val_\d+" value="([^"]*)"') |
              ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
  }
}
function Norm([string]$s) { ($s -replace '[\s\-_./·(),*\[\]]', '').ToLower() }

# ---------- 1. 우리 카탈로그 로드 ----------
$dataFile = Join-Path $PSScriptRoot 'data-edent.json'
if (-not (Test-Path $dataFile)) { throw "data-edent.json 이 없습니다. 먼저 crawl.ps1 을 실행하세요." }
$data = Get-Content $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
$ourIds = @{}
$known = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($it in $data.items) {
  $ourIds[[string]$it.id] = 1
  foreach ($f in @($it.name, $it.code, $it.spec, $it.company)) {
    if ($f) { [void]$known.Add((Norm $f)) }
  }
}
Write-Host "카탈로그 상품 $($ourIds.Count)개 / 기지값 $($known.Count)개"

# ---------- 2. 캐시 로드 ----------
$mapFile = Join-Path $PSScriptRoot 'keywords-map.json'
$map = @{}            # keyword -> pd_idx 배열
$tokensDone = @{}     # 처리 완료 토큰
$skipped = @{}        # 상품 매칭 없거나 너무 광범위한 문자열
if (Test-Path $mapFile) {
  try {
    $cache = Get-Content $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $cache.map.PSObject.Properties)   { $map[$p.Name] = @($p.Value) }
    foreach ($t in $cache.tokensDone)                 { $tokensDone[$t] = 1 }
    foreach ($s in $cache.skipped)                    { $skipped[$s] = 1 }
    Write-Host "캐시 로드: 키워드 $($map.Count) / 처리토큰 $($tokensDone.Count) / 제외 $($skipped.Count)"
  } catch { Write-Warning "캐시 로드 실패: $($_.Exception.Message)" }
}

# ---------- 3. 토큰 추출 (빈도 높은 순) ----------
$freq = @{}
foreach ($it in $data.items) {
  $txt = "$($it.name) $($it.spec)"
  foreach ($mm in [regex]::Matches($txt, '[A-Za-z]{4,}|[가-힣]{2,}')) {
    $t = $mm.Value.ToLower()
    $freq[$t] = ($freq[$t] + 1)
  }
}
$tokens = @($freq.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key } |
            Where-Object { -not $tokensDone.ContainsKey($_) })
Write-Host "토큰 후보 $($tokens.Count)개 (이번 실행 최대 $($TokenBudget)개)"

# ---------- 4. 자동완성으로 후보 문자열 수집 ----------
$cands = New-Object 'System.Collections.Generic.HashSet[string]'
$tk = 0
foreach ($t in $tokens) {
  if ($tk -ge $TokenBudget) { break }
  $tk++
  try {
    $page = 0
    while ($page -lt $MaxPages) {
      $a = Get-Auto $t $page
      if ($a.vals.Count -eq 0) { break }
      foreach ($v in $a.vals) {
        if (-not $v) { continue }
        $n = Norm $v
        if ($known.Contains($n)) { continue }        # 이미 아는 값(이름/코드/규격/회사)
        if ($map.ContainsKey($v) -or $skipped.ContainsKey($v)) { continue }
        [void]$cands.Add($v)
      }
      $page++
      if (($page * 20) -ge $a.total) { break }
      Start-Sleep -Milliseconds $DelayMs
    }
  } catch { Write-Warning "자동완성 실패 '$t'" }
  $tokensDone[$t] = 1
  if ($tk % 25 -eq 0) { Write-Host "  토큰 $tk/$TokenBudget · 후보 $($cands.Count)개" }
  Start-Sleep -Milliseconds $DelayMs
}
Write-Host "신규 후보 문자열: $($cands.Count)개"

# ---------- 5. 후보 → 상품 매핑 (검색 1회씩) ----------
$kw = 0; $hit = 0
foreach ($c in @($cands)) {
  if ($kw -ge $KeywordBudget) { break }
  $kw++
  try {
    $h = Get-Text "$Base/search/search.php?top_stx=$([System.Uri]::EscapeDataString($c))&top_sca=1"
    $ids = @([regex]::Matches($h, 'pd_idx=(\d+)') | ForEach-Object { $_.Groups[1].Value } |
             Sort-Object -Unique | Where-Object { $ourIds.ContainsKey($_) })
    if ($ids.Count -ge 1 -and $ids.Count -le 300) { $map[$c] = $ids; $hit++ }
    else { $skipped[$c] = 1 }
  } catch { $skipped[$c] = 1 }
  if ($kw % 50 -eq 0) { Write-Host "  키워드 $kw/$KeywordBudget · 확정 $hit개" }
  Start-Sleep -Milliseconds $DelayMs
}

# ---------- 6. 캐시 저장 ----------
$out = [ordered]@{
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  tokensDone  = @($tokensDone.Keys | Sort-Object)
  skipped     = @($skipped.Keys | Sort-Object)
  map         = [ordered]@{}
}
foreach ($k in ($map.Keys | Sort-Object)) { $out.map[$k] = $map[$k] }
[System.IO.File]::WriteAllText($mapFile, ($out | ConvertTo-Json -Depth 5), $enc)
Write-Host "완료: 키워드 $($map.Count)개 확정(이번 +$hit) · 처리토큰 $($tokensDone.Count)개 · keywords-map.json 저장"
