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

$payload = [ordered]@{
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  shops       = $shops
  count       = $all.Count
  items       = $all
}
$json = $payload | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data.js'),   "window.EDENT_DATA = $json;", $enc)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data.json'), $json, $enc)
Write-Host "통합 완료: 총 $($all.Count)개 → data.js / data.json"
