<#
TODO
 - clean up
#>
. "$psscriptroot\..\lib\json.ps1"

. "$psscriptroot/core.ps1"
. "$psscriptroot/json.ps1"

function find_hash_in_rdf([String] $url, [String] $basename) {
    $data = $null
    try {
        # Download and parse RDF XML file
        $wc = New-Object Net.Webclient
        $wc.Headers.Add('Referer', (strip_filename $url))
        $wc.Headers.Add('User-Agent', (Get-UserAgent))
        [xml]$data = $wc.downloadstring($url)
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return $null
    }

    # Find file content
    $digest = $data.RDF.Content | Where-Object { [String]$_.about -eq $basename }

    return format_hash $digest.sha256
}

function find_hash_in_textfile([String] $url, [Hashtable] $substitutions, [String] $regex) {
    $hashfile = $null

    $templates = @{
        '$md5' = '([a-fA-F0-9]{32})';
        '$sha1' = '([a-fA-F0-9]{40})';
        '$sha256' = '([a-fA-F0-9]{64})';
        '$sha512' = '([a-fA-F0-9]{128})';
        '$checksum' = '([a-fA-F0-9]{32,128})';
        '$base64' = '([a-zA-Z0-9+\/=]{24,88})';
    }

    try {
        $wc = New-Object Net.Webclient
        $wc.Headers.Add('Referer', (strip_filename $url))
        $wc.Headers.Add('User-Agent', (Get-UserAgent))
        $hashfile = $wc.downloadstring($url)
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return
    }

    if ($regex.Length -eq 0) {
        $regex = '^([a-fA-F0-9]+)$'
    }

    $regex = substitute $regex $templates $false
    $regex = substitute $regex $substitutions $true
    debug $regex
    if ($hashfile -match $regex) {
        $hash = $matches[1] -replace '\s',''
    }

    # convert base64 encoded hash values
    if ($hash -match '^(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=|[A-Za-z0-9+\/]{4})$') {
        $base64 = $matches[0]
        if(!($hash -match '^[a-fA-F0-9]+$') -and $hash.length -notin @(32, 40, 64, 128)) {
            try {
                $hash = ([System.Convert]::FromBase64String($base64) | ForEach-Object { $_.ToString('x2') }) -join ''
            } catch {
                $hash = $hash
            }
        }
    }

    # find hash with filename in $hashfile
    if ($hash.Length -eq 0) {
        $filenameRegex = "([a-fA-F0-9]{32,128})[\x20\t]+.*`$basename(?:[\x20\t]+\d+)?"
        $filenameRegex = substitute $filenameRegex $substitutions $true
        if ($hashfile -match $filenameRegex) {
            $hash = $matches[1]
        }
        $metalinkRegex = "<hash[^>]+>([a-fA-F0-9]{64})"
        if ($hashfile -match $metalinkRegex) {
            $hash = $matches[1]
        }
    }

    return format_hash $hash
}

function find_hash_in_json([String] $url, [Hashtable] $substitutions, [String] $jsonpath) {
    $json = $null

    try {
        $wc = New-Object Net.Webclient
        $wc.Headers.Add('Referer', (strip_filename $url))
        $wc.Headers.Add('User-Agent', (Get-UserAgent))
        $json = $wc.downloadstring($url)
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return
    }
    $hash = json_path $json $jsonpath $substitutions
    if(!$hash) {
        $hash = json_path_legacy $json $jsonpath $substitutions
    }
    return format_hash $hash
}

function find_hash_in_xml([String] $url, [Hashtable] $substitutions, [String] $xpath) {
    $xml = $null

    try {
        $wc = New-Object Net.Webclient
        $wc.Headers.Add('Referer', (strip_filename $url))
        $wc.Headers.Add('User-Agent', (Get-UserAgent))
        $xml = [xml]$wc.downloadstring($url)
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return
    }

    # Replace placeholders
    if ($substitutions) {
        $xpath = substitute $xpath $substitutions
    }

    # Find all `significant namespace declarations` from the XML file
    $nsList = $xml.SelectNodes("//namespace::*[not(. = ../../namespace::*)]")
    # Then add them into the NamespaceManager
    $nsmgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsList | ForEach-Object {
        $nsmgr.AddNamespace($_.LocalName, $_.Value)
    }

    # Getting hash from XML, using XPath
    $hash = $xml.SelectSingleNode($xpath, $nsmgr).'#text'
    return format_hash $hash
}

function find_hash_in_headers([String] $url) {
    $hash = $null

    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Referer = (strip_filename $url)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = (Get-UserAgent)
        $req.Timeout = 2000
        $req.Method = 'HEAD'
        $res = $req.GetResponse()
        if(([int]$response.StatusCode -ge 300) -and ([int]$response.StatusCode -lt 400)) {
            if($res.Headers['Digest'] -match 'SHA-256=([^,]+)' -or $res.Headers['Digest'] -match 'SHA=([^,]+)' -or $res.Headers['Digest'] -match 'MD5=([^,]+)') {
                $hash = ([System.Convert]::FromBase64String($matches[1]) | ForEach-Object { $_.ToString('x2') }) -join ''
                debug $hash
            }
        }
        $res.Close()
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return
    }

    return format_hash $hash
}

function get_hash_for_app([String] $app, $config, [String] $version, [String] $url, [Hashtable] $substitutions) {
    $hash = $null

    $hashmode = $config.mode
    $basename = url_remote_filename($url)

    $substitutions = $substitutions.Clone()
    $substitutions.Add('$url', (strip_fragment $url))
    $substitutions.Add('$baseurl', (strip_filename (strip_fragment $url)).TrimEnd('/'))
    $substitutions.Add('$basename', $basename)
    debug $substitutions

    $hashfile_url = substitute $config.url $substitutions
    debug $hashfile_url
    if ($hashfile_url) {
        write-host -f DarkYellow 'Searching hash for ' -NoNewline
        write-host -f Green $basename -NoNewline
        write-host -f DarkYellow ' in ' -NoNewline
        write-host -f Green $hashfile_url
    }

    if ($hashmode.Length -eq 0 -and $config.url.Length -ne 0) {
        $hashmode = 'extract'
    }

    $jsonpath = ''
    if ($config.jp) {
        $jsonpath = $config.jp
        $hashmode = 'json'
    }
    if ($config.jsonpath) {
        $jsonpath = $config.jsonpath
        $hashmode = 'json'
    }
    $regex = ''
    if ($config.find) {
        $regex = $config.find
    }
    if ($config.regex) {
        $regex = $config.regex
    }

    $xpath = ''
    if ($config.xpath) {
        $xpath = $config.xpath
        $hashmode = 'xpath'
    }

    if (!$hashfile_url -and $url -match "^(?:.*fosshub.com\/).*(?:\/|\?dwl=)(?<filename>.*)$") {
        $hashmode = 'fosshub'
    }

    if (!$hashfile_url -and $url -match "(?:downloads\.)?sourceforge.net\/projects?\/(?<project>[^\/]+)\/(?:files\/)?(?<file>.*)") {
        $hashmode = 'sourceforge'
    }

    switch ($hashmode) {
        'extract' {
            $hash = find_hash_in_textfile $hashfile_url $substitutions $regex
        }
        'json' {
            $hash = find_hash_in_json $hashfile_url $substitutions $jsonpath
        }
        'xpath' {
            $hash = find_hash_in_xml $hashfile_url $substitutions $xpath
        }
        'rdf' {
            $hash = find_hash_in_rdf $hashfile_url $basename
        }
        'metalink' {
            $hash = find_hash_in_headers $url
            if (!$hash) {
                $hash = find_hash_in_textfile "$url.meta4" $substitutions
            }
        }
        'fosshub' {
            $hash = find_hash_in_textfile $url $substitutions ($Matches.filename+'.*?"sha256":"([a-fA-F0-9]{64})"')
        }
        'sourceforge' {
            # change the URL because downloads.sourceforge.net doesn't have checksums
            $hashfile_url = (strip_filename (strip_fragment "https://sourceforge.net/projects/$($matches['project'])/files/$($matches['file'])")).TrimEnd('/')
            $hash = find_hash_in_textfile $hashfile_url $substitutions '"$basename":.*?"sha1":\s"([a-fA-F0-9]{40})"'
        }
    }

    if ($hash) {
        # got one!
        write-host -f DarkYellow 'Found: ' -NoNewline
        write-host -f Green $hash -NoNewline
        write-host -f DarkYellow ' using ' -NoNewline
        write-host -f Green  "$((Get-Culture).TextInfo.ToTitleCase($hashmode)) Mode"
        return $hash
    } elseif ($hashfile_url) {
        write-host -f DarkYellow "Could not find hash in $hashfile_url"
    }

    write-host -f DarkYellow 'Downloading ' -NoNewline
    write-host -f Green $basename -NoNewline
    write-host -f DarkYellow ' to compute hashes!'
    try {
        dl_with_cache $app $version $url $null $null $true
    } catch [system.net.webexception] {
        write-host -f darkred $_
        write-host -f darkred "URL $url is not valid"
        return $null
    }
    $file = fullpath (cache_path $app $version $url)
    $hash = compute_hash $file 'sha256'
    write-host -f DarkYellow 'Computed hash: ' -NoNewline
    write-host -f Green $hash
    return $hash
}

function Update-ManifestProperty {
    <#
    .SYNOPSIS
        Update propert(y|ies) in manifest
    .DESCRIPTION
        Update selected propert(y|ies) to given version in manifest.
    .PARAMETER Manifest
        Manifest to be updated
    .PARAMETER Property
        Selected propert(y|ies) to be updated
    .PARAMETER AppName
        Software name
    .PARAMETER Version
        Given software version
    .PARAMETER Substitutions
        Hashtable of internal substitutable variables
    .OUTPUTS
        System.Boolean
            Flag that indicate if there are any changed properties
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true, Position = 1)]
        [PSCustomObject]
        $Manifest,
        [Parameter(ValueFromPipeline = $true, Position = 2)]
        [String[]]
        $Property,
        [String]
        $AppName,
        [String]
        $Version,
        [Alias('Matches')]
        [HashTable]
        $Substitutions
    )
    begin {
        $hasManifestChanged = $false
    }
    process {
        foreach ($currentProperty in $Property) {
            if ($currentProperty -eq 'hash') {
                # Update hash
                if ($Manifest.hash) {
                    # Global
                    $newURL = substitute $Manifest.autoupdate.url $Substitutions
                    $newHash = HashHelper -AppName $AppName -Version $Version -HashExtraction $Manifest.autoupdate.hash -URL $newURL -Substitutions $Substitutions
                    $Manifest.hash, $hasPropertyChanged = PropertyHelper -Property $Manifest.hash -Value $newHash
                    $hasManifestChanged = $hasManifestChanged -or $hasPropertyChanged
                } else {
                    # Arch-spec
                    $Manifest.architecture | Get-Member -MemberType NoteProperty | ForEach-Object {
                        $arch = $_.Name
                        $newURL = substitute (arch_specific 'url' $Manifest.autoupdate $arch) $Substitutions
                        $newHash = HashHelper -AppName $AppName -Version $Version -HashExtraction (arch_specific 'hash' $Manifest.autoupdate $arch) -URL $newURL -Substitutions $Substitutions
                        $Manifest.architecture.$arch.hash, $hasPropertyChanged = PropertyHelper -Property $Manifest.architecture.$arch.hash -Value $newHash
                        $hasManifestChanged = $hasManifestChanged -or $hasPropertyChanged
                    }
                }
            } elseif ($Manifest.$currentProperty -and $Manifest.autoupdate.$currentProperty) {
                # Update other property (global)
                $newValue = substitute $Manifest.autoupdate.$currentProperty $Substitutions
                $Manifest.$currentProperty, $hasPropertyChanged = PropertyHelper -Property $Manifest.$currentProperty -Value $newValue
                $hasManifestChanged = $hasManifestChanged -or $hasPropertyChanged
            } elseif ($Manifest.architecture) {
                # Update other property (arch-spec)
                $Manifest.architecture | Get-Member -MemberType NoteProperty | ForEach-Object {
                    $arch = $_.Name
                    if ($Manifest.architecture.$arch.$currentProperty -and ($Manifest.autoupdate.architecture.$arch.$currentProperty -or $Manifest.autoupdate.$currentProperty)) {
                        $newValue = substitute (arch_specific $currentProperty $Manifest.autoupdate $arch) $Substitutions
                        $Manifest.architecture.$arch.$currentProperty, $hasPropertyChanged = PropertyHelper -Property $Manifest.architecture.$arch.$currentProperty -Value $newValue
                        $hasManifestChanged = $hasManifestChanged -or $hasPropertyChanged
                    }
                }
            }
        }
    }
    end {
        if ($Version -ne '' -and $Manifest.version -ne $Version) {
            $Manifest.version = $Version
            $hasManifestChanged = $true
        }
        return $hasManifestChanged
    }
}

function get_version_substitutions([String] $version, [Hashtable] $customMatches) {
    $firstPart = $version.Split('-') | Select-Object -first 1
    $lastPart = $version.Split('-') | Select-Object -last 1
    $versionVariables = @{
        '$version' = $version;
        '$underscoreVersion' = ($version -replace "\.", "_");
        '$dashVersion' = ($version -replace "\.", "-");
        '$cleanVersion' = ($version -replace "\.", "");
        '$majorVersion' = $firstPart.Split('.') | Select-Object -first 1;
        '$minorVersion' = $firstPart.Split('.') | Select-Object -skip 1 -first 1;
        '$patchVersion' = $firstPart.Split('.') | Select-Object -skip 2 -first 1;
        '$buildVersion' = $firstPart.Split('.') | Select-Object -skip 3 -first 1;
        '$preReleaseVersion' = $lastPart;
    }
    if($version -match "(?<head>\d+\.\d+(?:\.\d+)?)(?<tail>.*)") {
        $versionVariables.Set_Item('$matchHead', $matches['head'])
        $versionVariables.Set_Item('$matchTail', $matches['tail'])
    }
    if($customMatches) {
        $customMatches.GetEnumerator() | ForEach-Object {
            if($_.Name -ne "0") {
                $versionVariables.Set_Item('$match' + (Get-Culture).TextInfo.ToTitleCase($_.Name), $_.Value)
            }
        }
    }
    return $versionVariables
}

function autoupdate([String] $app, $dir, $json, [String] $version, [Hashtable] $matches) {
    Write-Host -f DarkCyan "Autoupdating $app"
    $substitutions = get_version_substitutions $version $matches

    # update properties
    $updatedProperties = @(@($json.autoupdate.PSObject.Properties.Name) -ne 'architecture')
    if ($json.autoupdate.architecture) {
        $updatedProperties += $json.autoupdate.architecture.PSObject.Properties | ForEach-Object { $_.Value.PSObject.Properties.Name } | Select-Object -Unique
    }
    if (!($updatedProperties -eq 'hash')) {
        $updatedProperties += 'hash'
    }
    debug [Array]$updatedProperties
    $hasChanged = Update-ManifestProperty -Manifest $json -Property $updatedProperties -AppName $app -Version $version -Substitutions $substitutions

    if ($hasChanged) {
        # write file
        Write-Host -f DarkGreen "Writing updated $app manifest"
        $json | ConvertToPrettyJson | Set-Content (Join-Path $dir "$app.json") -Encoding ASCII
        # notes
        if ($json.autoupdate.note) {
            Write-Host ""
            Write-Host -f DarkYellow $json.autoupdate.note
        }
    } else {
        Write-Host -f DarkGray "No updates for $app"
    }
}

## Helper Functions

function PropertyHelper {
    <#
    .SYNOPSIS
        Helper of updating property
    .DESCRIPTION
        Update manifest property (String, Array or PSCustomObject).
    .PARAMETER Property
        Property to be updated
    .PARAMETER Value
        New property values
        Update line by line
    .OUTPUTS
        System.Object[]
            The first element is new property, the second element is change flag
    #>
    param (
        [Object]$Property,
        [Object]$Value
    )
    $hasChanged = $false
    switch ($Property.GetType().Name) {
        'String' {
            $Value = $Value -as [String]
            if (($null -ne $Value) -and ($value -ne $Property)) {
                $Property = $Value
                $hasChanged = $true
            }
        }
        'Object[]' {
            $Value = @($Value)
            for ($i = 0; $i -lt [Math]::Min($Property.Length, $Value.Length); $i++) {
                $Property[$i], $hasItemChanged = PropertyHelper -Property $Property[$i] -Value $Value[$i]
                $hasChanged = $hasChanged -or $hasItemChanged
            }
        }
        'PSCustomObject' {
            if ($Value -is [PSObject]) {
                foreach ($name in $Property.PSObject.Properties.Name) {
                    if ($Value.$name) {
                        $Property.$name, $hasItemChanged = PropertyHelper -Property $Property.$name -Value $Value.$name
                        $hasChanged = $hasChanged -or $hasItemChanged
                    }
                }
            }
        }
    }
    return $Property, $hasChanged
}

function HashHelper {
    <#
    .SYNOPSIS
        Helper of getting file hash(es)
    .DESCRIPTION
        Get file hash(es) by hash extraction template(s).
        If hash extraction templates are less then URLs, the last template will be reused for the rest URLs.
    .PARAMETER AppName
        Software name
    .PARAMETER Version
        Given software version
    .PARAMETER HashExtraction
        Hash extraction template(s)
    .PARAMETER URL
        New download URL(s), used to calculate hash locally
    .PARAMETER Substitutions
        Hashtable of internal substitutable variables
    .OUTPUTS
        System.String
            Hash value (single URL)
        System.String[]
            Hash values (multi URLs)
    #>
    param (
        [String]
        $AppName,
        [String]
        $Version,
        [PSObject[]]
        $HashExtraction,
        [String[]]
        $URL,
        [HashTable]
        $Substitutions
    )
    $hash = @()
    for ($i = 0; $i -lt $URL.Length; $i++) {
        if ($null -eq $HashExtraction) {
            $currentHashExtraction = $null
        } else {
            $currentHashExtraction = $HashExtraction[$i], $HashExtraction[-1] | Select-Object -First 1
        }
        $hash += get_hash_for_app $AppName $currentHashExtraction $Version $URL[$i] $Substitutions
        if ($null -eq $hash[$i]) {
            throw "Could not update $AppName, hash for $($URL[$i]) failed!"
        }
    }
    return $hash
}
