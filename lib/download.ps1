
function dl_with_cache($app, $version, $url, $to, $cookies = $null, $use_cache = $true) {
    $cached = fullpath (cache_path $app $version $url)

    if(!(test-path $cached) -or !$use_cache) {
        ensure $cachedir | Out-Null
        do_dl $url "$cached.download" $cookies
        Move-Item "$cached.download" $cached -force
    } else { write-host "Loading $(url_remote_filename $url) from cache"}

    if (!($null -eq $to)) {
        Copy-Item $cached $to
    }
}

function do_dl($url, $to, $cookies) {
    $progress = [console]::isoutputredirected -eq $false -and
        $host.name -ne 'Windows PowerShell ISE Host'

    try {
        $url = handle_special_urls $url
        dl $url $to $cookies $progress
    } catch {
        $e = $_.exception
        if($e.innerexception) { $e = $e.innerexception }
        throw $e
    }
}

function aria_exit_code($exitcode) {
    $codes = @{
        0='All downloads were successful'
        1='An unknown error occurred'
        2='Timeout'
        3='Resource was not found'
        4='Aria2 saw the specified number of "resource not found" error. See --max-file-not-found option'
        5='Download aborted because download speed was too slow. See --lowest-speed-limit option'
        6='Network problem occurred.'
        7='There were unfinished downloads. This error is only reported if all finished downloads were successful and there were unfinished downloads in a queue when aria2 exited by pressing Ctrl-C by an user or sending TERM or INT signal'
        8='Remote server did not support resume when resume was required to complete download'
        9='There was not enough disk space available'
        10='Piece length was different from one in .aria2 control file. See --allow-piece-length-change option'
        11='Aria2 was downloading same file at that moment'
        12='Aria2 was downloading same info hash torrent at that moment'
        13='File already existed. See --allow-overwrite option'
        14='Renaming file failed. See --auto-file-renaming option'
        15='Aria2 could not open existing file'
        16='Aria2 could not create new file or truncate existing file'
        17='File I/O error occurred'
        18='Aria2 could not create directory'
        19='Name resolution failed'
        20='Aria2 could not parse Metalink document'
        21='FTP command failed'
        22='HTTP response header was bad or unexpected'
        23='Too many redirects occurred'
        24='HTTP authorization failed'
        25='Aria2 could not parse bencoded file (usually ".torrent" file)'
        26='".torrent" file was corrupted or missing information that aria2 needed'
        27='Magnet URI was bad'
        28='Bad/unrecognized option was given or unexpected option argument was given'
        29='The remote server was unable to handle the request due to a temporary overloading or maintenance'
        30='Aria2 could not parse JSON-RPC request'
        31='Reserved. Not used'
        32='Checksum validation failed'
    }
    if($null -eq $codes[$exitcode]) {
        return 'An unknown error occurred'
    }
    return $codes[$exitcode]
}

function get_filename_from_metalink($file) {
    $bytes = get_magic_bytes_pretty $file ''
    # check if file starts with '<?xml'
    if(!($bytes.StartsWith('3c3f786d6c'))) {
        return $null
    }

    # Add System.Xml for reading metalink files
    Add-Type -AssemblyName 'System.Xml'
    $xr = [System.Xml.XmlReader]::Create($file)
    $filename = $null
    try {
        $xr.ReadStartElement('metalink')
        if($xr.ReadToFollowing('file') -and $xr.MoveToFirstAttribute()) {
            $filename = $xr.Value
        }
    } catch [System.Xml.XmlException] {
        return $null
    } finally {
        $xr.Close()
    }

    return $filename
}

function dl_with_cache_aria2($app, $version, $manifest, $architecture, $dir, $cookies = $null, $use_cache = $true, $check_hash = $true) {
    $data = @{}
    $urls = @(url $manifest $architecture)

    # aria2 input file
    $urlstxt = Join-Path $cachedir "$app.txt"
    $urlstxt_content = ''
    $has_downloads = $false

    # aria2 options
    $options = @(
        "--input-file='$urlstxt'"
        "--user-agent='$(Get-UserAgent)'"
        "--allow-overwrite=true"
        "--auto-file-renaming=false"
        "--retry-wait=$(get_config 'aria2-retry-wait' 2)"
        "--split=$(get_config 'aria2-split' 5)"
        "--max-connection-per-server=$(get_config 'aria2-max-connection-per-server' 5)"
        "--min-split-size=$(get_config 'aria2-min-split-size' '5M')"
        "--console-log-level=warn"
        "--enable-color=false"
        "--no-conf=true"
        "--follow-metalink=true"
        "--metalink-preferred-protocol=https"
        "--min-tls-version=TLSv1.2"
        "--stop-with-process=$PID"
        "--continue"
    )

    if($cookies) {
        $options += "--header='Cookie: $(cookie_header $cookies)'"
    }

    $proxy = get_config 'proxy'
    if($proxy -ne 'none') {
        if([Net.Webrequest]::DefaultWebProxy.Address) {
            $options += "--all-proxy='$([Net.Webrequest]::DefaultWebProxy.Address.Authority)'"
        }
        if([Net.Webrequest]::DefaultWebProxy.Credentials.UserName) {
            $options += "--all-proxy-user='$([Net.Webrequest]::DefaultWebProxy.Credentials.UserName)'"
        }
        if([Net.Webrequest]::DefaultWebProxy.Credentials.Password) {
            $options += "--all-proxy-passwd='$([Net.Webrequest]::DefaultWebProxy.Credentials.Password)'"
        }
    }

    $more_options = get_config 'aria2-options'
    if($more_options) {
        $options += $more_options
    }

    foreach($url in $urls) {
        $data.$url = @{
            'filename' = url_filename $url
            'target' = "$dir\$(url_filename $url)"
            'cachename' = fname (cache_path $app $version $url)
            'source' = fullpath (cache_path $app $version $url)
        }

        if(!(test-path $data.$url.source)) {
            $has_downloads = $true
            # create aria2 input file content
            $urlstxt_content += "$(handle_special_urls $url)`n"
            if(!$url.Contains('sourceforge.net')) {
                $urlstxt_content += "    referer=$(strip_filename $url)`n"
            }
            $urlstxt_content += "    dir=$cachedir`n"
            $urlstxt_content += "    out=$($data.$url.cachename)`n"
        } else {
            Write-Host "Loading " -NoNewline
            Write-Host $(url_remote_filename $url) -f Cyan -NoNewline
            Write-Host " from cache."
        }
    }

    if($has_downloads) {
        # write aria2 input file
        Set-Content -Path $urlstxt $urlstxt_content

        # build aria2 command
        $aria2 = "& '$(Get-HelperPath -Helper Aria2)' $($options -join ' ')"

        # handle aria2 console output
        Write-Host "Starting download with aria2 ..."
        $prefix = "Download: "
        Invoke-Expression $aria2 | ForEach-Object {
            if([String]::IsNullOrWhiteSpace($_)) {
                # skip blank lines
                return
            }
            Write-Host $prefix -NoNewline
            if($_.StartsWith('(OK):')) {
                Write-Host $_ -f Green
            } elseif($_.StartsWith('[') -and $_.EndsWith(']')) {
                Write-Host $_ -f Cyan
            } else {
                Write-Host $_ -f Gray
            }
        }

        if($lastexitcode -gt 0) {
            error "Download failed! (Error $lastexitcode) $(aria_exit_code $lastexitcode)"
            error $urlstxt_content
            error $aria2
            abort $(new_issue_msg $app $bucket "download via aria2 failed")
        }

        # remove aria2 input file when done
        if(test-path($urlstxt)) {
            Remove-Item $urlstxt
        }
    }

    foreach($url in $urls) {

        $metalink_filename = get_filename_from_metalink $data.$url.source
        if($metalink_filename) {
            Remove-Item $data.$url.source -Force
            Rename-Item -Force (Join-Path -Path $cachedir -ChildPath $metalink_filename) $data.$url.source
        }

        # run hash checks
        if($check_hash) {
            $manifest_hash = hash_for_url $manifest $url $architecture
            $ok, $err = check_hash $data.$url.source $manifest_hash $(show_app $app $bucket)
            if(!$ok) {
                error $err
                if(test-path $data.$url.source) {
                    # rm cached file
                    Remove-Item -force $data.$url.source
                }
                if($url.Contains('sourceforge.net')) {
                    Write-Host -f yellow 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.'
                }
                abort $(new_issue_msg $app $bucket "hash check failed")
            }
        }

        # copy or move file to target location
        if(!(test-path $data.$url.source) ) {
            abort $(new_issue_msg $app $bucket "cached file not found")
        }

        if(!($dir -eq $cachedir)) {
            if($use_cache) {
                Copy-Item $data.$url.source $data.$url.target
            } else {
                Move-Item $data.$url.source $data.$url.target -force
            }
        }
    }
}

# download with filesize and progress indicator
function dl($url, $to, $cookies, $progress) {
    $reqUrl = ($url -split "#")[0]
    $wreq = [net.webrequest]::create($reqUrl)
    if($wreq -is [net.httpwebrequest]) {
        $wreq.useragent = Get-UserAgent
        if (-not ($url -imatch "sourceforge\.net")) {
            $wreq.referer = strip_filename $url
        }
        if($cookies) {
            $wreq.headers.add('Cookie', (cookie_header $cookies))
        }
    }

    $wres = $wreq.getresponse()
    $total = $wres.ContentLength
    if($total -eq -1 -and $wreq -is [net.ftpwebrequest]) {
        $total = ftp_file_size($url)
    }

    if ($progress -and ($total -gt 0)) {
        [console]::CursorVisible = $false
        function dl_onProgress($read) {
            dl_progress $read $total $url
        }
    } else {
        write-host "Downloading $url ($(filesize $total))..."
        function dl_onProgress {
            #no op
        }
    }

    try {
        $s = $wres.getresponsestream()
        $fs = [io.file]::openwrite($to)
        $buffer = new-object byte[] 2048
        $totalRead = 0
        $sw = [diagnostics.stopwatch]::StartNew()

        dl_onProgress $totalRead
        while(($read = $s.read($buffer, 0, $buffer.length)) -gt 0) {
            $fs.write($buffer, 0, $read)
            $totalRead += $read
            if ($sw.elapsedmilliseconds -gt 100) {
                $sw.restart()
                dl_onProgress $totalRead
            }
        }
        $sw.stop()
        dl_onProgress $totalRead
    } finally {
        if ($progress) {
            [console]::CursorVisible = $true
            write-host
        }
        if ($fs) {
            $fs.close()
        }
        if ($s) {
            $s.close();
        }
        $wres.close()
    }
}

function dl_progress_output($url, $read, $total, $console) {
    $filename = url_remote_filename $url

    # calculate current percentage done
    $p = [math]::Round($read / $total * 100, 0)

    # pre-generate LHS and RHS of progress string
    # so we know how much space we have
    $left  = "$filename ($(filesize $total))"
    $right = [string]::Format("{0,3}%", $p)

    # calculate remaining width for progress bar
    $midwidth  = $console.BufferSize.Width - ($left.Length + $right.Length + 8)

    # calculate how many characters are completed
    $completed = [math]::Abs([math]::Round(($p / 100) * $midwidth, 0) - 1)

    # generate dashes to symbolise completed
    if ($completed -gt 1) {
        $dashes = [string]::Join("", ((1..$completed) | ForEach-Object {"="}))
    }

    # this is why we calculate $completed - 1 above
    $dashes += switch($p) {
        100 {"="}
        default {">"}
    }

    # the remaining characters are filled with spaces
    $spaces = switch($dashes.Length) {
        $midwidth {[string]::Empty}
        default {
            [string]::Join("", ((1..($midwidth - $dashes.Length)) | ForEach-Object {" "}))
        }
    }

    "$left [$dashes$spaces] $right"
}

function dl_progress($read, $total, $url) {
    $console = $host.UI.RawUI;
    $left  = $console.CursorPosition.X;
    $top   = $console.CursorPosition.Y;
    $width = $console.BufferSize.Width;

    if($read -eq 0) {
        $maxOutputLength = $(dl_progress_output $url 100 $total $console).length
        if (($left + $maxOutputLength) -gt $width) {
            # not enough room to print progress on this line
            # print on new line
            write-host
            $left = 0
            $top  = $top + 1
        }
    }

    write-host $(dl_progress_output $url $read $total $console) -nonewline
    [console]::SetCursorPosition($left, $top)
}

function dl_urls($app, $version, $manifest, $bucket, $architecture, $dir, $use_cache = $true, $check_hash = $true) {
    # we only want to show this warning once
    if(!$use_cache) { warn "Cache is being ignored." }

    # can be multiple urls: if there are, then msi or installer should go last,
    # so that $fname is set properly
    $urls = @(url $manifest $architecture)

    # can be multiple cookies: they will be used for all HTTP requests.
    $cookies = $manifest.cookie

    $fname = $null

    # extract_dir and extract_to in manifest are like queues: for each url that
    # needs to be extracted, will get the next dir from the queue
    $extract_dirs = @(extract_dir $manifest $architecture)
    $extract_tos = @(extract_to $manifest $architecture)
    $extracted = 0;

    # download first
    if(Test-Aria2Enabled) {
        dl_with_cache_aria2 $app $version $manifest $architecture $dir $cookies $use_cache $check_hash
    } else {
        foreach($url in $urls) {
            $fname = url_filename $url

            try {
                dl_with_cache $app $version $url "$dir\$fname" $cookies $use_cache
            } catch {
                write-host -f darkred $_
                abort "URL $url is not valid"
            }

            if($check_hash) {
                $manifest_hash = hash_for_url $manifest $url $architecture
                $ok, $err = check_hash "$dir\$fname" $manifest_hash $(show_app $app $bucket)
                if(!$ok) {
                    error $err
                    $cached = cache_path $app $version $url
                    if(test-path $cached) {
                        # rm cached file
                        Remove-Item -force $cached
                    }
                    if($url.Contains('sourceforge.net')) {
                        Write-Host -f yellow 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.'
                    }
                    abort $(new_issue_msg $app $bucket "hash check failed")
                }
            }
        }
    }

    foreach($url in $urls) {
        $fname = url_filename $url

        $extract_dir = $extract_dirs[$extracted]
        $extract_to = $extract_tos[$extracted]

        # work out extraction method, if applicable
        $extract_fn = $null
        if ($manifest.innosetup) {
            $extract_fn = 'Expand-InnoArchive'
        } elseif($fname -match '\.zip$') {
            # Use 7zip when available (more fast)
            if (((get_config 7ZIPEXTRACT_USE_EXTERNAL) -and (Test-CommandAvailable 7z)) -or (Test-HelperInstalled -Helper 7zip)) {
                $extract_fn = 'Expand-7zipArchive'
            } else {
                $extract_fn = 'Expand-ZipArchive'
            }
        } elseif($fname -match '\.msi$') {
            # check manifest doesn't use deprecated install method
            if(msi $manifest $architecture) {
                warn "MSI install is deprecated. If you maintain this manifest, please refer to the manifest reference docs."
            } else {
                $extract_fn = 'Expand-MsiArchive'
            }
        } elseif(Test-7zipRequirement -File $fname) { # 7zip
            $extract_fn = 'Expand-7zipArchive'
        }

        if($extract_fn) {
            Write-Host "Extracting " -NoNewline
            Write-Host $fname -f Cyan -NoNewline
            Write-Host " ... " -NoNewline
            & $extract_fn -Path "$dir\$fname" -DestinationPath "$dir\$extract_to" -ExtractDir $extract_dir -Removal
            Write-Host "done." -f Green
            $extracted++
        }
    }

    $fname # returns the last downloaded file
}

function cookie_header($cookies) {
    if(!$cookies) { return }

    $vals = $cookies.psobject.properties | ForEach-Object {
        "$($_.name)=$($_.value)"
    }

    [string]::join(';', $vals)
}

function ftp_file_size($url) {
    $request = [net.ftpwebrequest]::create($url)
    $request.method = [net.webrequestmethods+ftp]::getfilesize
    $request.getresponse().contentlength
}

# hashes
function hash_for_url($manifest, $url, $arch) {
    $hashes = @(hash $manifest $arch) | Where-Object { $_ -ne $null };

    if($hashes.length -eq 0) { return $null }

    $urls = @(url $manifest $arch)

    $index = [array]::indexof($urls, $url)
    if($index -eq -1) { abort "Couldn't find hash in manifest for '$url'." }

    @($hashes)[$index]
}

# returns (ok, err)
function check_hash($file, $hash, $app_name) {
    $file = fullpath $file
    if(!$hash) {
        warn "Warning: No hash in manifest. SHA256 for '$(fname $file)' is:`n    $(compute_hash $file 'sha256')"
        return $true, $null
    }

    Write-Host "Checking hash of " -NoNewline
    Write-Host $(url_remote_filename $url) -f Cyan -NoNewline
    Write-Host " ... " -nonewline
    $algorithm, $expected = get_hash $hash
    if ($null -eq $algorithm) {
        return $false, "Hash type '$algorithm' isn't supported."
    }

    $actual = compute_hash $file $algorithm
    $expected = $expected.ToLower()

    if($actual -ne $expected) {
        $msg = "Hash check failed!`n"
        $msg += "App:         $app_name`n"
        $msg += "URL:         $url`n"
        if(Test-Path $file) {
            $msg += "First bytes: $((get_magic_bytes_pretty $file ' ').ToUpper())`n"
        }
        if($expected -or $actual) {
            $msg += "Expected:    $expected`n"
            $msg += "Actual:      $actual"
        }
        return $false, $msg
    }
    Write-Host "ok." -f Green
    return $true, $null
}

function compute_hash($file, $algname) {
    try {
        if(Test-CommandAvailable Get-FileHash) {
            return (Get-FileHash -Path $file -Algorithm $algname).Hash.ToLower()
        } else {
            $fs = [system.io.file]::openread($file)
            $alg = [system.security.cryptography.hashalgorithm]::create($algname)
            $hexbytes = $alg.computehash($fs) | ForEach-Object { $_.tostring('x2') }
            return [string]::join('', $hexbytes)
        }
    } catch {
        error $_.exception.message
    } finally {
        if($fs) { $fs.dispose() }
        if($alg) { $alg.dispose() }
    }
    return ''
}

function format_hash([String] $hash) {
    $hash = $hash.toLower()
    switch ($hash.Length)
    {
        32 { $hash = "md5:$hash" } # md5
        40 { $hash = "sha1:$hash" } # sha1
        64 { $hash = $hash } # sha256
        128 { $hash = "sha512:$hash" } # sha512
        default { $hash = $null }
    }
    return $hash
}

function format_hash_aria2([String] $hash) {
    $hash = $hash -split ':' | Select-Object -Last 1
    switch ($hash.Length)
    {
        32 { $hash = "md5=$hash" } # md5
        40 { $hash = "sha-1=$hash" } # sha1
        64 { $hash = "sha-256=$hash" } # sha256
        128 { $hash = "sha-512=$hash" } # sha512
        default { $hash = $null }
    }
    return $hash
}

function get_hash([String] $multihash) {
    $type, $hash = $multihash -split ':'
    if(!$hash) {
        # no type specified, assume sha256
        $type, $hash = 'sha256', $multihash
    }

    if(@('md5','sha1','sha256', 'sha512') -notcontains $type) {
        return $null, "Hash type '$type' isn't supported."
    }

    return $type, $hash.ToLower()
}

function handle_special_urls($url)
{
    # FossHub.com
    if ($url -match "^(?:.*fosshub.com\/)(?<name>.*)(?:\/|\?dwl=)(?<filename>.*)$") {
        $Body = @{
            projectUri      = $Matches.name;
            fileName        = $Matches.filename;
            isLatestVersion = $true
        }
        if ((Invoke-RestMethod -Uri $url) -match '"p":"(?<pid>[a-f0-9]{24}).*?"r":"(?<rid>[a-f0-9]{24})') {
            $Body.Add("projectId", $Matches.pid)
            $Body.Add("releaseId", $Matches.rid)
        }
        $url = Invoke-RestMethod -Method Post -Uri "https://api.fosshub.com/download/" -ContentType "application/json" -Body (ConvertTo-Json $Body -Compress)
        if ($null -eq $url.error) {
            $url = $url.data.url
        }
    }

    # Sourceforge.net
    if ($url -match "(?:downloads\.)?sourceforge.net\/projects?\/(?<project>[^\/]+)\/(?:files\/)?(?<file>.*?)(?:$|\/download|\?)") {
        # Reshapes the URL to avoid redirections
        $url = "https://downloads.sourceforge.net/project/$($matches['project'])/$($matches['file'])"
    }
    return $url
}

function get_magic_bytes($file) {
    if(!(Test-Path $file)) {
        return ''
    }

    if((Get-Command Get-Content).parameters.ContainsKey('AsByteStream')) {
        # PowerShell Core (6.0+) '-Encoding byte' is replaced by '-AsByteStream'
        return Get-Content $file -AsByteStream -TotalCount 8
    }
    else {
        return Get-Content $file -Encoding byte -TotalCount 8
    }
}

function get_magic_bytes_pretty($file, $glue = ' ') {
    if(!(Test-Path $file)) {
        return ''
    }

    return (get_magic_bytes $file | ForEach-Object { $_.ToString('x2') }) -join $glue
}
