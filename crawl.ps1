# 이덴트(edent.co.kr) 상품 카탈로그 크롤러
# 사용법(로컬):  powershell -ExecutionPolicy Bypass -File crawl.ps1
#   자격증명은 secret.local.ps1(git 제외) 또는 환경변수 EDENT_ID / EDENT_PW 로 주입.
# 결과:  같은 폴더의 data.js / data.json 갱신
#
# 수집: 카테고리 트리(program/show_cate_all_make.php)에서 소분류(cate3) + 중분류(cate2)
#       버킷을 모두 순회, 목록 페이지(shop_list.php)만 요청하여 pd_idx로 dedup.
#       로그인 세션이면 회원가까지 수집(비로그인은 정가만).

param(
  [string]$Id = $env:EDENT_ID,
  [string]$Pw = $env:EDENT_PW,
  [int]$DelayMs = 1000,          # Crawl-delay 1초 준수
  [int]$MaxBuckets = 0           # 0=전체, >0이면 테스트용 제한
)

$ErrorActionPreference = 'Stop'
$Base = 'https://www.edent.co.kr'
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# ---- 로컬 자격증명 파일 (git 제외) ----
$secretFile = Join-Path $PSScriptRoot 'secret.local.ps1'
if ((-not $Id -or -not $Pw) -and (Test-Path $secretFile)) {
  . $secretFile
  if (-not $Id) { $Id = $env:EDENT_ID }
  if (-not $Pw) { $Pw = $env:EDENT_PW }
}

$script:session = $null

function Get-Html([string]$url) {
  $r = Invoke-WebRequest -Uri $url -WebSession $script:session -UserAgent $ua -UseBasicParsing -TimeoutSec 40
  $bytes = $r.RawContentStream.ToArray()
  return [System.Text.Encoding]::UTF8.GetString($bytes)   # UTF-8 강제(한글 깨짐 방지)
}
function Dec([string]$s) { [System.Net.WebUtility]::HtmlDecode($s).Trim() }
function ToInt($s) { if ($s) { [int]((($s) -replace '[^\d]', '')) } else { $null } }

# ================= 1. 세션 + 로그인 =================
Invoke-WebRequest -Uri "$Base/member/login.php" -UserAgent $ua -SessionVariable session -UseBasicParsing -TimeoutSec 40 | Out-Null
$script:session = $session
$loggedIn = $false
if ($Id -and $Pw) {
  try {
    $body = @{ id = $Id; pw = $Pw; save_id = '0'; backurl = '/index.php' }
    Invoke-WebRequest -Uri "$Base/member/login_process.php" -Method Post -Body $body `
      -WebSession $script:session -UserAgent $ua -UseBasicParsing -TimeoutSec 40 | Out-Null
    $chk = Get-Html "$Base/index.php"
    if ($chk -match 'logout|로그아웃|MYPAGE|마이페이지') { $loggedIn = $true }
  } catch { Write-Warning "로그인 실패: $($_.Exception.Message)" }
}
Write-Host ("로그인 상태: {0}" -f $(if ($loggedIn) { '성공 → 회원가 수집' } else { '미로그인 → 정가만 수집' }))

# ================= 2. 카테고리 트리 파싱 =================
# <span class="title">대분류</span> ... <span class="blueTitle">중분류</span> ... <a ...cate3=..>소분류</a>
$tree = Get-Html "$Base/program/show_cate_all_make.php"

$tokens = [regex]::Matches($tree,
  '(?s)class="title">(?<t>[^<]+)<|class="blueTitle">(?<b>[^<]+)<|shop_list\.php\?cate1=(?<c1>\d+)&cate2=(?<c2>\d+)&cate3=(?<c3>\d+)"[^>]*>(?<n>[^<]+)<')

$leaves = [System.Collections.Generic.List[object]]::new()
$c1Name = @{}; $c2Name = @{}
$curT = ''; $curB = ''
foreach ($m in $tokens) {
  if ($m.Groups['t'].Success)      { $curT = Dec $m.Groups['t'].Value }
  elseif ($m.Groups['b'].Success)  { $curB = Dec $m.Groups['b'].Value }
  elseif ($m.Groups['c3'].Success) {
    $a = $m.Groups['c1'].Value; $b = $m.Groups['c2'].Value; $d = $m.Groups['c3'].Value
    if (-not $c1Name.ContainsKey($a)) { $c1Name[$a] = $curT }
    $c2Name["$a-$b"] = $curB
    $leaves.Add([pscustomobject]@{ c1 = $a; c2 = $b; c3 = $d; c1n = $curT; c2n = $curB; c3n = (Dec $m.Groups['n'].Value) })
  }
}

# 버킷 = 소분류(cate3) 전부 + 중분류(cate2) 전부  (부모·자식 상호 비포함 → 합집합 필요)
$buckets = [System.Collections.Generic.List[object]]::new()
foreach ($lf in $leaves) {
  $buckets.Add([pscustomobject]@{
    url  = "$Base/shop/shop_list.php?cate1=$($lf.c1)&cate2=$($lf.c2)&cate3=$($lf.c3)"
    c1n  = $lf.c1n; c2n = $lf.c2n; c3n = $lf.c3n; depth = 3
  })
}
$c2seen = @{}
foreach ($lf in $leaves) {
  $k = "$($lf.c1)-$($lf.c2)"
  if ($c2seen.ContainsKey($k)) { continue }; $c2seen[$k] = 1
  $buckets.Add([pscustomobject]@{
    url  = "$Base/shop/shop_list.php?cate1=$($lf.c1)&cate2=$($lf.c2)"
    c1n  = $lf.c1n; c2n = $lf.c2n; c3n = ''; depth = 2
  })
}
if ($MaxBuckets -gt 0 -and $buckets.Count -gt $MaxBuckets) {
  $buckets = $buckets[0..($MaxBuckets - 1)]
}
Write-Host ("카테고리: 대 $($c1Name.Count) / 중 $($c2seen.Count) / 소 $($leaves.Count)  → 버킷 $($buckets.Count)개")

# ================= 3. 상품 파싱 =================
function Parse-Products([string]$html) {
  # 목록에는 두 레이아웃이 섞여 있음(추천 카드 / 메인 그리드 행). 둘 다 상품 단위로
  # "실구매 가격<br> ... <b>N@금액원</b>" 으로 끝나므로 이를 앵커로 상품을 분리한다.
  # 이름링크 → (다음 상품 링크 전까지) → 실구매가 볼드금액.  (추천/하단 링크는 실구매가 없어 자동 제외)
  $pat = '(?s)item\.php\?pd_idx=(\d+)[^"]*">([^<]+)</a>((?:(?!item\.php\?pd_idx).){0,1800}?)실구매\s*가격\s*<br>\s*<span[^>]*>\s*<b>\s*\d*@\s*([\d,]+)\s*원'
  $ms = [regex]::Matches($html, $pat)
  $seen = @{}; $out = [System.Collections.Generic.List[object]]::new()
  foreach ($m in $ms) {
    $pdid = $m.Groups[1].Value
    if ($seen.ContainsKey($pdid)) { continue }; $seen[$pdid] = 1
    $nm  = Dec $m.Groups[2].Value
    $mid = $m.Groups[3].Value
    $pReal = ToInt $m.Groups[4].Value

    # 원산지/브랜드: 이름 뒤 "[브랜드]" 또는 skyblue 뱃지
    $origin = ''
    if ($mid -match '^\s*<br>\s*\[([^\]]+)\]') { $origin = Dec $Matches[1] }
    elseif ($mid -match 'class="skyblue">([^<]+)<') { $origin = Dec $Matches[1] }

    # 정가: 첫 @금액원
    $pList = $null
    if ($mid -match '@\s*([\d,]+)\s*원') { $pList = ToInt $Matches[1] }
    # 회원가: 첫 @금액원 다음 줄의 @(…로그인 | 금액원). 로그인 세션이면 금액이 채워짐.
    $pMember = $null
    $mm = [regex]::Match($mid, '@\s*[\d,]+\s*원\s*<br>\s*\d*@\s*(?:(?:특가)?로그인|([\d,]+)\s*원)')
    if ($mm.Success -and $mm.Groups[1].Value) { $pMember = ToInt $mm.Groups[1].Value }

    $out.Add([pscustomobject]@{
      id = $pdid; name = $nm; origin = $origin
      priceList = $pList; priceMember = $pMember; priceReal = $pReal
    })
  }
  , $out
}

function Get-MaxPage([string]$html) {
  $p = [regex]::Matches($html, 'page=(\d+)&') | ForEach-Object { [int]$_.Groups[1].Value }
  if ($p) { ($p | Measure-Object -Maximum).Maximum } else { 1 }
}

# ================= 4. 순회 =================
$items = @{}   # id -> record
$reqCount = 0
$bi = 0
foreach ($bk in $buckets) {
  $bi++
  $page = 1; $maxp = 1
  while ($page -le $maxp) {
    $u = if ($page -eq 1) { $bk.url } else { "$($bk.url)&page=$page" }
    try { $html = Get-Html $u } catch { Write-Warning "요청 실패 $u : $($_.Exception.Message)"; break }
    $reqCount++
    if ($page -eq 1) { $maxp = Get-MaxPage $html }

    foreach ($p in (Parse-Products $html)) {
      $catPath = @($bk.c1n, $bk.c2n, $bk.c3n | Where-Object { $_ }) -join ' > '
      if ($items.ContainsKey($p.id)) {
        $rec = $items[$p.id]
        if ($rec.cats -notcontains $catPath) { $rec.cats += $catPath }
        # 더 구체적인(소분류) 카테고리를 대표값으로
        if ($bk.depth -eq 3 -and -not $rec.catLeaf) { $rec.catLeaf = $catPath; $rec.cat1 = $bk.c1n; $rec.cat2 = $bk.c2n }
        if ($null -eq $rec.priceList)   { $rec.priceList = $p.priceList }
        if ($null -eq $rec.priceMember) { $rec.priceMember = $p.priceMember }
        if ($null -eq $rec.priceReal)   { $rec.priceReal = $p.priceReal }
        if (-not $rec.origin) { $rec.origin = $p.origin }
      } else {
        $items[$p.id] = [pscustomobject]@{
          id = $p.id; name = $p.name; origin = $p.origin
          priceList = $p.priceList; priceMember = $p.priceMember; priceReal = $p.priceReal
          cat1 = $bk.c1n; cat2 = $bk.c2n
          catLeaf = $(if ($bk.depth -eq 3) { $catPath } else { '' })
          cats = @($catPath)
          img = "$Base/data/product/img_m1_$($p.id)"
          url = "$Base/shop/item.php?pd_idx=$($p.id)"
        }
      }
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    $page++
  }
  if ($bi % 25 -eq 0) { Write-Host ("  진행 $bi/$($buckets.Count) 버킷 · 요청 $reqCount · 상품 $($items.Count)") }
}

# ================= 5. 출력 =================
$list = $items.Values | Sort-Object name
$payload = [ordered]@{
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  loggedIn    = $loggedIn
  count       = $list.Count
  items       = $list
}
$json = $payload | ConvertTo-Json -Depth 6
$enc = New-Object System.Text.UTF8Encoding($false)   # BOM 없음
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data.js'),   "window.EDENT_DATA = $json;", $enc)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data.json'), $json, $enc)
Write-Host ("완료: 상품 $($list.Count)개 · 요청 $($reqCount)회 · 회원가수집 $loggedIn")
