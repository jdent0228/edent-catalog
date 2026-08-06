# 멀티샵 데이터 병합: data-edent.json + data-seil.json → data.js / data.json
# 사용법:  powershell -ExecutionPolicy Bypass -File build.ps1

$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)

$all = [System.Collections.Generic.List[object]]::new()
$shops = [ordered]@{}

foreach ($src in @(
  @{ file = 'data-edent.json'; shop = 'edent'; label = '이덴트' },
  @{ file = 'data-seil.json';  shop = 'seil';  label = '세일글로벌' }
)) {
  $f = Join-Path $PSScriptRoot $src.file
  if (-not (Test-Path $f)) { Write-Warning "$($src.file) 없음 — 건너뜀"; continue }
  $d = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
  $n = 0
  foreach ($it in $d.items) {
    if (-not $it.PSObject.Properties['shop'] -or -not $it.shop) {
      $it | Add-Member -NotePropertyName shop -NotePropertyValue $src.shop -Force
    }
    # 이름 공백 방어: 이름이 비면 규격으로 복원 (이름==규격 상품 트림 사고 등)
    if ((-not $it.name -or $it.name -match '^\s*$') -and $it.spec) { $it.name = $it.spec }
    $all.Add($it); $n++
  }
  $shops[$src.shop] = [ordered]@{ label = $src.label; count = $n; generatedAt = $d.generatedAt }
  Write-Host "$($src.label): $n개 ($($d.generatedAt))"
}

# 숨은 검색키워드 붙이기 (harvest-keywords.ps1 산출물)
$kwFile = Join-Path $PSScriptRoot 'keywords-map.json'
if (Test-Path $kwFile) {
  try {
    $kwCache = Get-Content $kwFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $byId = @{}
    foreach ($p in $kwCache.map.PSObject.Properties) {
      foreach ($id in $p.Value) {
        if (-not $byId.ContainsKey($id)) { $byId[$id] = [System.Collections.Generic.List[string]]::new() }
        $byId[$id].Add($p.Name)
      }
    }
    $applied = 0
    foreach ($it in $all) {
      if ($it.shop -ne 'edent') { continue }
      $k = [string]$it.id
      if ($byId.ContainsKey($k)) {
        $it | Add-Member -NotePropertyName kw -NotePropertyValue ($byId[$k] -join ' ') -Force
        $applied++
      }
    }
    Write-Host "숨은 키워드 적용: 상품 $applied개 (키워드 $($kwCache.map.PSObject.Properties.Count)종)"
  } catch { Write-Warning "keywords-map.json 적용 실패: $($_.Exception.Message)" }
}

# 안전장치: 병합 결과가 비정상적으로 적으면 기존 data.js를 덮어쓰지 않는다
$prevCount = 0
$prevFile = Join-Path $PSScriptRoot 'data.js'
if (Test-Path $prevFile) {
  try {
    $head = (Get-Content $prevFile -TotalCount 1 -Encoding UTF8)
    $mm = [regex]::Match($head, '"count":(\d+)')
    if ($mm.Success) { $prevCount = [int]$mm.Groups[1].Value }
  } catch {}
}
if ($prevCount -gt 1000 -and $all.Count -lt [int]($prevCount * 0.6)) {
  throw "병합 결과 이상: $($all.Count)개 (직전 $prevCount개). data.js를 덮어쓰지 않고 중단합니다."
}

# ---- 공백 없는 압축 JSON 직접 생성 (ConvertTo-Json은 들여쓰기로 용량이 2배가 됨) ----
function JStr([string]$s) {
  if ($null -eq $s -or $s -eq '') { return '""' }
  $t = $s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", ' ' -replace "`t", ' '
  $t = $t -replace '[\x00-\x1F]', ''
  '"' + $t + '"'
}
function JNum($v) { if ($null -eq $v) { 'null' } else { [string][int]$v } }

# 뷰어가 쓰지 않거나(cats/catLeaf/hasGroup) 계산 가능한(url, edent img) 필드는 싣지 않는다
$sb = [System.Text.StringBuilder]::new(20MB)
[void]$sb.Append('window.EDENT_DATA={"generatedAt":').Append((JStr (Get-Date).ToString('yyyy-MM-dd HH:mm')))
[void]$sb.Append(',"shops":{')
$first = $true
foreach ($k in $shops.Keys) {
  if (-not $first) { [void]$sb.Append(',') }; $first = $false
  [void]$sb.Append((JStr $k)).Append(':{"label":').Append((JStr $shops[$k].label))
  [void]$sb.Append(',"count":').Append($shops[$k].count)
  [void]$sb.Append(',"generatedAt":').Append((JStr $shops[$k].generatedAt)).Append('}')
}
[void]$sb.Append('},"count":').Append($all.Count).Append(',"items":[')
$n = 0
foreach ($it in $all) {
  if ($n -gt 0) { [void]$sb.Append(',') }
  $n++
  [void]$sb.Append('{"id":').Append((JStr ([string]$it.id)))
  [void]$sb.Append(',"shop":').Append((JStr ([string]$it.shop)))
  [void]$sb.Append(',"name":').Append((JStr ([string]$it.name)))
  if ($it.company) { [void]$sb.Append(',"company":').Append((JStr ([string]$it.company))) }
  if ($it.country) { [void]$sb.Append(',"country":').Append((JStr ([string]$it.country))) }
  if ($it.spec)    { [void]$sb.Append(',"spec":').Append((JStr ([string]$it.spec))) }
  if ($it.pkg)     { [void]$sb.Append(',"pkg":').Append((JStr ([string]$it.pkg))) }
  if ($it.code)    { [void]$sb.Append(',"code":').Append((JStr ([string]$it.code))) }
  if ($it.cat1)    { [void]$sb.Append(',"cat1":').Append((JStr ([string]$it.cat1))) }
  if ($it.cat2)    { [void]$sb.Append(',"cat2":').Append((JStr ([string]$it.cat2))) }
  if ($null -ne $it.priceList)   { [void]$sb.Append(',"priceList":').Append((JNum $it.priceList)) }
  if ($null -ne $it.priceMember) { [void]$sb.Append(',"priceMember":').Append((JNum $it.priceMember)) }
  if ($null -ne $it.priceReal)   { [void]$sb.Append(',"priceReal":').Append((JNum $it.priceReal)) }
  if ($it.gid -and $it.gid -ne 'solo') { [void]$sb.Append(',"gid":').Append((JStr ([string]$it.gid))) }
  if ($it.PSObject.Properties['kw'] -and $it.kw) { [void]$sb.Append(',"kw":').Append((JStr ([string]$it.kw))) }
  # 이덴트 이미지는 id로 계산 가능 → 세일글로벌만 저장
  if ($it.shop -ne 'edent' -and $it.img) { [void]$sb.Append(',"img":').Append((JStr ([string]$it.img))) }
  [void]$sb.Append('}')
}
[void]$sb.Append(']};')
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data.js'), $sb.ToString(), $enc)
$mb = [Math]::Round((Get-Item (Join-Path $PSScriptRoot 'data.js')).Length / 1MB, 1)
Write-Host "통합 완료: 총 $($all.Count)개 → data.js ($mb MB)"
