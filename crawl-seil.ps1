# 세일글로벌(seilglobal.co.kr) 상품 카탈로그 크롤러 (MakeShop, EUC-KR)
# 사용법:  powershell -ExecutionPolicy Bypass -File crawl-seil.ps1
# 결과:  data-seil.json (비로그인 판매가 기준; robots.txt 전면 허용)
#
# 목록 구조: shopbrand.html?xcode=XX&page=N — <tr class="item-list"> 단위
#   thumb img(MS_prod_img_m) | prd-name(branduid+이름) | prd-standard(규격) |
#   prd-brand(회사) | prd-code(상품코드) | strike 소비자가 | span.memberPrice 판매가

param(
  [int]$DelayMs = 700,
  [int]$MaxCats = 0            # 0=전체, >0 테스트용
)

$ErrorActionPreference = 'Stop'
$Base = 'https://www.seilglobal.co.kr'
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$kr   = [System.Text.Encoding]::GetEncoding('euc-kr')

function Get-Html([string]$url) {
  $r = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 40
  $kr.GetString($r.RawContentStream.ToArray())
}
function Dec([string]$s) { [System.Net.WebUtility]::HtmlDecode($s).Trim() }
function ToInt($s) { if ($s) { [int]((($s) -replace '[^\d]', '')) } else { $null } }

# ================= 1. 카테고리(xcode) 목록 + 이름 =================
# 데스크톱 GNB는 이미지 메뉴라 이름이 없음 → 모바일(m.seilglobal.co.kr)의 텍스트 메뉴에서
# 전체 xcode 목록과 이름을 수집 (커버리지도 모바일이 훨씬 넓음: ~130개 vs 25개)
$catName = @{}
$xcodeSet = @{}
foreach ($src in @("http://m.seilglobal.co.kr/", "$Base/")) {
  try { $navHtml = Get-Html $src } catch { Write-Warning "메뉴 로드 실패: $src"; continue }
  foreach ($m in [regex]::Matches($navHtml, '(?s)<a[^>]+shopbrand\.html\?xcode=(\d+)[^"]*"[^>]*>(.*?)</a>')) {
    $xc = $m.Groups[1].Value
    $xcodeSet[$xc] = 1
    $nm = Dec ((($m.Groups[2].Value -replace '<[^>]+>', '') -replace '\s+', ' ') -replace '\s*>\s*$', '')
    if ($nm -and $nm.Length -ge 2 -and $nm.Length -le 30 -and -not $catName.ContainsKey($xc)) { $catName[$xc] = $nm }
  }
}
$xcodes = @($xcodeSet.Keys | Sort-Object)
if ($MaxCats -gt 0 -and $xcodes.Count -gt $MaxCats) { $xcodes = $xcodes[0..($MaxCats - 1)] }
Write-Host "세일글로벌 카테고리: $($xcodes.Count)개 (이름 확보 $($catName.Count)개)"

# ================= 2. 목록 파싱 =================
function Parse-SeilList([string]$html) {
  $out = [System.Collections.Generic.List[object]]::new()
  $rows = [regex]::Matches($html, '(?s)<tr class="item-list">(.*?)</tr>')
  foreach ($r in $rows) {
    $b = $r.Groups[1].Value
    $idM = [regex]::Match($b, 'branduid=(\d+)')
    if (-not $idM.Success) { continue }
    $bid = $idM.Groups[1].Value

    $nm = ''
    $nmM = [regex]::Match($b, '(?s)class="prd-name"[^>]*>\s*<a[^>]*>(.*?)</a>')
    if ($nmM.Success) { $nm = Dec (($nmM.Groups[1].Value) -replace '<[^>]+>', '') }
    if (-not $nm) { continue }

    $spec = ''
    if ($b -match 'class="prd-standard"[^>]*>([^<]*)<') { $spec = Dec $Matches[1] }
    $brand = ''
    if ($b -match 'class="prd-brand"[^>]*>([^<]*)<') { $brand = Dec $Matches[1] }
    $code = ''
    if ($b -match 'class="prd-code"[^>]*>[^:<]*:\s*([^<]+)<') { $code = (Dec $Matches[1]) }

    $pList = $null
    if ($b -match '<strike>[^<]*?([\d,]{3,})\s*원') { $pList = ToInt $Matches[1] }
    $pSell = $null
    if ($b -match 'class="memberPrice"[^>]*>\s*([\d,]+)\s*<') { $pSell = ToInt $Matches[1] }
    elseif ($b -match '판매가[^\d]{0,30}([\d,]{3,})\s*원') { $pSell = ToInt $Matches[1] }

    $img = ''
    $imgM = [regex]::Match($b, '<img[^>]+class="MS_prod_img_m"[^>]+src="([^"]+)"')
    if (-not $imgM.Success) { $imgM = [regex]::Match($b, 'class="thumb"[\s\S]{0,300}?<img[^>]+src="([^"]+)"') }
    if ($imgM.Success) {
      $img = $imgM.Groups[1].Value
      if ($img.StartsWith('//')) { $img = 'https:' + $img }
      elseif ($img.StartsWith('/')) { $img = $Base + $img }
    }

    $out.Add([pscustomobject]@{
      id = $bid; name = $nm; spec = $spec; company = $brand; code = $code
      priceList = $pList; priceSell = $pSell; img = $img
    })
  }
  , $out
}

# ================= 3. 순회 =================
$items = @{}
$reqCount = 0
$ci = 0
foreach ($xc in $xcodes) {
  $ci++
  $c1 = if ($catName.ContainsKey($xc)) { $catName[$xc] } else { "분류$xc" }
  $page = 1
  $prevIds = ''
  while ($true) {
    try { $html = Get-Html "$Base/shop/shopbrand.html?xcode=$xc&page=$page" }
    catch { Write-Warning "요청 실패 xcode=$xc p$page"; break }
    $reqCount++
    $rows = Parse-SeilList $html
    if ($rows.Count -eq 0) { break }
    # 같은 목록 반복(마지막 페이지 초과) 감지
    $idsSig = ($rows | ForEach-Object { $_.id }) -join ','
    if ($idsSig -eq $prevIds) { break }
    $prevIds = $idsSig

    foreach ($p in $rows) {
      if ($items.ContainsKey($p.id)) {
        $rec = $items[$p.id]
        if ($rec.cats -notcontains $c1) { $rec.cats += $c1 }
        continue
      }
      $items[$p.id] = [pscustomobject]@{
        id = $p.id; name = $p.name; company = $p.company; country = ''
        spec = $p.spec
        priceList = $p.priceList; priceMember = $null; priceReal = $p.priceSell
        cat1 = $c1; cat2 = ''; catLeaf = ''; cats = @($c1)
        img = $p.img
        url = "$Base/shop/shopdetail.html?branduid=$($p.id)"
        pkg = ''; gid = ''; hasGroup = $false; code = $p.code
        shop = 'seil'
      }
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    $page++
    if ($page -gt 60) { break }   # 안전장치
  }
  Write-Host "  [$ci/$($xcodes.Count)] $c1 (xcode=$xc) 누적 $($items.Count)"
}

# ================= 4. 출력 =================
$list = $items.Values | Sort-Object name
$payload = [ordered]@{
  shop        = 'seil'
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  count       = $list.Count
  items       = $list
}
$json = $payload | ConvertTo-Json -Depth 6
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data-seil.json'), $json, $enc)
Write-Host "완료: 세일글로벌 $($list.Count)개 · 요청 $($reqCount)회"
