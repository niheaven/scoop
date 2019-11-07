. "$psscriptroot/autoupdate.ps1"
. "$psscriptroot/buckets.ps1"
. "$psscriptroot/download.ps1"

function nightly_version($date, $quiet = $false) {
    $date_str = $date.tostring("yyyyMMdd")
    if (!$quiet) {
        warn "This is a nightly version. Downloaded files won't be verified."
    }
    "nightly-$date_str"
}

function install_app($app, $architecture, $global, $suggested, $use_cache = $true, $check_hash = $true) {
    $app, $bucket, $null = parse_app $app
    $app, $manifest, $bucket, $url = Find-Manifest $app $bucket

    if(!$manifest) {
        abort "Couldn't find manifest for '$app'$(if($url) { " at the URL $url" })."
    }

    $version = $manifest.version
    if(!$version) { abort "Manifest doesn't specify a version." }
    if($version -match '[^\w\.\-\+_]') {
        abort "Manifest version has unsupported character '$($matches[0])'."
    }

    $is_nightly = $version -eq 'nightly'
    if ($is_nightly) {
        $version = nightly_version $(get-date)
        $check_hash = $false
    }

    if(!(supports_architecture $manifest $architecture)) {
        write-host -f DarkRed "'$app' doesn't support $architecture architecture!"
        return
    }

    write-output "Installing '$app' ($version) [$architecture]"

    $dir = ensure (versiondir $app $version $global)
    $original_dir = $dir # keep reference to real (not linked) directory
    $persist_dir = persistdir $app $global

    $fname = dl_urls $app $version $manifest $bucket $architecture $dir $use_cache $check_hash
    pre_install $manifest $architecture
    run_installer $fname $manifest $architecture $dir $global
    ensure_install_dir_not_in_path $dir $global
    $dir = link_current $dir
    create_shims $manifest $dir $global $architecture
    create_startmenu_shortcuts $manifest $dir $global $architecture
    install_psmodule $manifest $dir $global
    if($global) { ensure_scoop_in_path $global } # can assume local scoop is in path
    env_add_path $manifest $dir $global $architecture
    env_set $manifest $dir $global $architecture

    # persist data
    persist_data $manifest $original_dir $persist_dir
    persist_permission $manifest $global

    post_install $manifest $architecture

    # save info for uninstall
    save_installed_manifest $app $bucket $dir $url
    save_install_info @{ 'architecture' = $architecture; 'url' = $url; 'bucket' = $bucket } $dir

    if($manifest.suggest) {
        $suggested[$app] = $manifest.suggest
    }

    success "'$app' ($version) was installed successfully!"

    show_notes $manifest $dir $original_dir $persist_dir
}

function locate($app, $bucket) {
    Show-DeprecatedWarning $MyInvocation 'Find-Manifest'
    return Find-Manifest $app $bucket
}

function Find-Manifest($app, $bucket) {
    $manifest, $url = $null, $null

    # check if app is a URL or UNC path
    if($app -match '^(ht|f)tps?://|\\\\') {
        $url = $app
        $app = appname_from_url $url
        $manifest = url_manifest $url
    } else {
        # check buckets
        $manifest, $bucket = find_manifest $app $bucket

        if(!$manifest) {
            # couldn't find app in buckets: check if it's a local path
            $path = $app
            if(!$path.endswith('.json')) { $path += '.json' }
            if(test-path $path) {
                $url = "$(resolve-path $path)"
                $app = appname_from_url $url
                $manifest, $bucket = url_manifest $url
            }
        }
    }

    return $app, $manifest, $bucket, $url
}

function is_in_dir($dir, $check) {
    $check = "$(fullpath $check)"
    $dir = "$(fullpath $dir)"
    $check -match "^$([regex]::escape("$dir"))(\\|`$)"
}

# for dealing with installers
function args($config, $dir, $global) {
    if($config) { return $config | ForEach-Object { (format $_ @{'dir'=$dir;'global'=$global}) } }
    @()
}

function run_installer($fname, $manifest, $architecture, $dir, $global) {
    # MSI or other installer
    $msi = msi $manifest $architecture
    $installer = installer $manifest $architecture
    if($installer.script) {
        write-output "Running installer script..."
        Invoke-Expression (@($installer.script) -join "`r`n")
        return
    }

    if($msi) {
        install_msi $fname $dir $msi
    } elseif($installer) {
        install_prog $fname $dir $installer $global
    }
}

# deprecated (see also msi_installed)
function install_msi($fname, $dir, $msi) {
    $msifile = "$dir\$(coalesce $msi.file "$fname")"
    if(!(is_in_dir $dir $msifile)) {
        abort "Error in manifest: MSI file $msifile is outside the app directory."
    }
    if(!($msi.code)) { abort "Error in manifest: Couldn't find MSI code."}
    if(msi_installed $msi.code) { abort "The MSI package is already installed on this system." }

    $logfile = "$dir\install.log"

    $arg = @("/i `"$msifile`"", '/norestart', "/lvp `"$logfile`"", "TARGETDIR=`"$dir`"",
        "INSTALLDIR=`"$dir`"") + @(args $msi.args $dir)

    if($msi.silent) { $arg += '/qn', 'ALLUSERS=2', 'MSIINSTALLPERUSER=1' }
    else { $arg += '/qb-!' }

    $continue_exit_codes = @{ 3010 = "a restart is required to complete installation" }

    $installed = Invoke-ExternalCommand 'msiexec' $arg -Activity "Running installer..." -ContinueExitCodes $continue_exit_codes
    if(!$installed) {
        abort "Installation aborted. You might need to run 'scoop uninstall $app' before trying again."
    }
    Remove-Item $logfile
    Remove-Item $msifile
}

# deprecated
# get-wmiobject win32_product is slow and checks integrity of each installed program,
# so this uses the [wmi] type accelerator instead
# http://blogs.technet.com/b/heyscriptingguy/archive/2011/12/14/use-powershell-to-find-and-uninstall-software.aspx
function msi_installed($code) {
    $path = "hklm:\software\microsoft\windows\currentversion\uninstall\$code"
    if(!(test-path $path)) { return $false }
    $key = Get-Item $path
    $name = $key.getvalue('displayname')
    $version = $key.getvalue('displayversion')
    $classkey = "IdentifyingNumber=`"$code`",Name=`"$name`",Version=`"$version`""
    try { $wmi = [wmi]"Win32_Product.$classkey"; $true } catch { $false }
}

function install_prog($fname, $dir, $installer, $global) {
    $prog = "$dir\$(coalesce $installer.file "$fname")"
    if(!(is_in_dir $dir $prog)) {
        abort "Error in manifest: Installer $prog is outside the app directory."
    }
    $arg = @(args $installer.args $dir $global)

    if($prog.endswith('.ps1')) {
        & $prog @arg
    } else {
        $installed = Invoke-ExternalCommand $prog $arg -Activity "Running installer..."
        if(!$installed) {
            abort "Installation aborted. You might need to run 'scoop uninstall $app' before trying again."
        }

        # Don't remove installer if "keep" flag is set to true
        if(!($installer.keep -eq "true")) {
            Remove-Item $prog
        }
    }
}

function run_uninstaller($manifest, $architecture, $dir) {
    $msi = msi $manifest $architecture
    $uninstaller = uninstaller $manifest $architecture
    $version = $manifest.version
    if($uninstaller.script) {
        write-output "Running uninstaller script..."
        Invoke-Expression (@($uninstaller.script) -join "`r`n")
        return
    }

    if($msi -or $uninstaller) {
        $exe = $null; $arg = $null; $continue_exit_codes = @{}

        if($msi) {
            $code = $msi.code
            $exe = "msiexec";
            $arg = @("/norestart", "/x $code")
            if($msi.silent) {
                $arg += '/qn', 'ALLUSERS=2', 'MSIINSTALLPERUSER=1'
            } else {
                $arg += '/qb-!'
            }

            $continue_exit_codes.1605 = 'not installed, skipping'
            $continue_exit_codes.3010 = 'restart required'
        } elseif($uninstaller) {
            $exe = "$dir\$($uninstaller.file)"
            $arg = args $uninstaller.args
            if(!(is_in_dir $dir $exe)) {
                warn "Error in manifest: Installer $exe is outside the app directory, skipping."
                $exe = $null;
            } elseif(!(test-path $exe)) {
                warn "Uninstaller $exe is missing, skipping."
                $exe = $null;
            }
        }

        if($exe) {
            if($exe.endswith('.ps1')) {
                & $exe @arg
            } else {
                $uninstalled = Invoke-ExternalCommand $exe $arg -Activity "Running uninstaller..." -ContinueExitCodes $continue_exit_codes
                if(!$uninstalled) { abort "Uninstallation aborted." }
            }
        }
    }
}

# get target, name, arguments for shim
function shim_def($item) {
    if($item -is [array]) { return $item }
    return $item, (strip_ext (fname $item)), $null
}

function create_shims($manifest, $dir, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)
    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $arg = shim_def $_
        write-output "Creating shim for '$name'."

        if(test-path "$dir\$target" -pathType leaf) {
            $bin = "$dir\$target"
        } elseif(test-path $target -pathType leaf) {
            $bin = $target
        } else {
            $bin = search_in_path $target
        }
        if(!$bin) { abort "Can't shim '$target': File doesn't exist."}

        shim $bin $global $name (substitute $arg @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir})
    }
}

function rm_shim($name, $shimdir) {
    $shim = "$shimdir\$name.ps1"

    if(!(test-path $shim)) { # handle no shim from failed install
        warn "Shim for '$name' is missing. Skipping."
    } else {
        write-output "Removing shim for '$name'."
        Remove-Item $shim
    }

    # other shim types might be present
    '', '.exe', '.shim', '.cmd' | ForEach-Object {
        if(test-path -Path "$shimdir\$name$_" -PathType leaf) {
            Remove-Item "$shimdir\$name$_"
        }
    }
}

function rm_shims($manifest, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)

    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $null = shim_def $_
        $shimdir = shimdir $global

        rm_shim $name $shimdir
    }
}

# Gets the path for the 'current' directory junction for
# the specified version directory.
function current_dir($versiondir) {
    $parent = split-path $versiondir
    return "$parent\current"
}


# Creates or updates the directory junction for [app]/current,
# pointing to the specified version directory for the app.
#
# Returns the 'current' junction directory if in use, otherwise
# the version directory.
function link_current($versiondir) {
    if(get_config NO_JUNCTIONS) { return $versiondir }

    $currentdir = current_dir $versiondir

    write-host "Linking $(friendly_path $currentdir) => $(friendly_path $versiondir)"

    if($currentdir -eq $versiondir) {
        abort "Error: Version 'current' is not allowed!"
    }

    if(test-path $currentdir) {
        # remove the junction
        attrib -R /L $currentdir
        & "$env:COMSPEC" /c rmdir $currentdir
    }

    & "$env:COMSPEC" /c mklink /j $currentdir $versiondir | out-null
    attrib $currentdir +R /L
    return $currentdir
}

# Removes the directory junction for [app]/current which
# points to the current version directory for the app.
#
# Returns the 'current' junction directory (if it exists),
# otherwise the normal version directory.
function unlink_current($versiondir) {
    if(get_config NO_JUNCTIONS) { return $versiondir }
    $currentdir = current_dir $versiondir

    if(test-path $currentdir) {
        write-host "Unlinking $(friendly_path $currentdir)"

        # remove read-only attribute on link
        attrib $currentdir -R /L

        # remove the junction
        & "$env:COMSPEC" /c "rmdir `"$currentdir`""
        return $currentdir
    }
    return $versiondir
}

# to undo after installers add to path so that scoop manifest can keep track of this instead
function ensure_install_dir_not_in_path($dir, $global) {
    $path = (env 'path' $global)

    $fixed, $removed = find_dir_or_subdir $path "$dir"
    if($removed) {
        $removed | ForEach-Object { "Installer added '$(friendly_path $_)' to path. Removing."}
        env 'path' $global $fixed
    }

    if(!$global) {
        $fixed, $removed = find_dir_or_subdir (env 'path' $true) "$dir"
        if($removed) {
            $removed | ForEach-Object { warn "Installer added '$_' to system path. You might want to remove this manually (requires admin permission)."}
        }
    }
}

function find_dir_or_subdir($path, $dir) {
    $dir = $dir.trimend('\')
    $fixed = @()
    $removed = @()
    $path.split(';') | ForEach-Object {
        if($_) {
            if(($_ -eq $dir) -or ($_ -like "$dir\*")) { $removed += $_ }
            else { $fixed += $_ }
        }
    }
    return [string]::join(';', $fixed), $removed
}

function env_add_path($manifest, $dir, $global, $arch) {
    $env_add_path = arch_specific 'env_add_path' $manifest $arch
    $env_add_path | Where-Object { $_ } | ForEach-Object {
        $path_dir = Join-Path $dir $_

        if (!(is_in_dir $dir $path_dir)) {
            abort "Error in manifest: env_add_path '$_' is outside the app directory."
        }
        add_first_in_path $path_dir $global
    }
}

function env_rm_path($manifest, $dir, $global, $arch) {
    $env_add_path = arch_specific 'env_add_path' $manifest $arch
    $env_add_path | Where-Object { $_ } | ForEach-Object {
        $path_dir = Join-Path $dir $_

        remove_from_path $path_dir $global
    }
}

function env_set($manifest, $dir, $global, $arch) {
    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -Member NoteProperty | ForEach-Object {
            $name = $_.name;
            $val = format $env_set.$($_.name) @{ "dir" = $dir }
            env $name $global $val
            Set-Content env:\$name $val
        }
    }
}
function env_rm($manifest, $global, $arch) {
    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -Member NoteProperty | ForEach-Object {
            $name = $_.name
            env $name $global $null
            if (Test-Path env:\$name) { Remove-Item env:\$name }
        }
    }
}

function pre_install($manifest, $arch) {
    $pre_install = arch_specific 'pre_install' $manifest $arch
    if($pre_install) {
        write-output "Running pre-install script..."
        Invoke-Expression (@($pre_install) -join "`r`n")
    }
}

function post_install($manifest, $arch) {
    $post_install = arch_specific 'post_install' $manifest $arch
    if($post_install) {
        write-output "Running post-install script..."
        Invoke-Expression (@($post_install) -join "`r`n")
    }
}

function show_notes($manifest, $dir, $original_dir, $persist_dir) {
    if($manifest.notes) {
        write-output "Notes"
        write-output "-----"
        write-output (wraptext (substitute $manifest.notes @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir}))
    }
}

function all_installed($apps, $global) {
    $apps | Where-Object {
        $app, $null, $null = parse_app $_
        installed $app $global
    }
}

# returns (uninstalled, installed)
function prune_installed($apps, $global) {
    $installed = @(all_installed $apps $global)

    $uninstalled = $apps | Where-Object { $installed -notcontains $_ }

    return @($uninstalled), @($installed)
}

# check whether the app failed to install
function failed($app, $global) {
    $ver = current_version $app $global
    if(!$ver) { return $false }
    $info = install_info $app $ver $global
    if(!$info) { return $true }
    return $false
}

function ensure_none_failed($apps, $global) {
    foreach($app in $apps) {
        if(failed $app $global) {
            abort "'$app' install failed previously. Please uninstall it and try again."
        }
    }
}

function show_suggestions($suggested) {
    $installed_apps = (installed_apps $true) + (installed_apps $false)

    foreach($app in $suggested.keys) {
        $features = $suggested[$app] | get-member -type noteproperty | ForEach-Object { $_.name }
        foreach($feature in $features) {
            $feature_suggestions = $suggested[$app].$feature

            $fulfilled = $false
            foreach($suggestion in $feature_suggestions) {
                $suggested_app, $bucket, $null = parse_app $suggestion

                if($installed_apps -contains $suggested_app) {
                    $fulfilled = $true;
                    break;
                }
            }

            if(!$fulfilled) {
                write-host "'$app' suggests installing '$([string]::join("' or '", $feature_suggestions))'."
            }
        }
    }
}

# Persistent data
function persist_def($persist) {
    if ($persist -is [Array]) {
        $source = $persist[0]
        $target = $persist[1]
    } else {
        $source = $persist
        $target = $null
    }

    if (!$target) {
        $target = $source
    }

    return $source, $target
}

function persist_data($manifest, $original_dir, $persist_dir) {
    $persist = $manifest.persist
    if($persist) {
        $persist_dir = ensure $persist_dir

        if ($persist -is [String]) {
            $persist = @($persist);
        }

        $persist | ForEach-Object {
            $source, $target = persist_def $_

            write-host "Persisting $source"

            $source = $source.TrimEnd("/").TrimEnd("\\")

            $source = fullpath "$dir\$source"
            $target = fullpath "$persist_dir\$target"

            # if we have had persist data in the store, just create link and go
            if (Test-Path $target) {
                # if there is also a source data, rename it (to keep a original backup)
                if (Test-Path $source) {
                    Move-Item -Force $source "$source.original"
                }
            # we don't have persist data in the store, move the source to target, then create link
            } elseif (Test-Path $source) {
                # ensure target parent folder exist
                ensure (Split-Path -Path $target) | Out-Null
                Move-Item $source $target
            # we don't have neither source nor target data! we need to crate an empty target,
            # but we can't make a judgement that the data should be a file or directory...
            # so we create a directory by default. to avoid this, use pre_install
            # to create the source file before persisting (DON'T use post_install)
            } else {
                $target = New-Object System.IO.DirectoryInfo($target)
                ensure $target | Out-Null
            }

            # create link
            if (is_directory $target) {
                # target is a directory, create junction
                & "$env:COMSPEC" /c "mklink /j `"$source`" `"$target`"" | out-null
                attrib $source +R /L
            } else {
                # target is a file, create hard link
                & "$env:COMSPEC" /c "mklink /h `"$source`" `"$target`"" | out-null
            }
        }
    }
}

function unlink_persist_data($dir) {
    # unlink all junction / hard link in the directory
    Get-ChildItem -Recurse $dir | ForEach-Object {
        $file = $_
        if ($null -ne $file.LinkType) {
            $filepath = $file.FullName
            # directory (junction)
            if ($file -is [System.IO.DirectoryInfo]) {
                # remove read-only attribute on the link
                attrib -R /L $filepath
                # remove the junction
                & "$env:COMSPEC" /c "rmdir /s /q `"$filepath`""
            } else {
                # remove the hard link
                & "$env:COMSPEC" /c "del `"$filepath`""
            }
        }
    }
}

# check whether write permission for Users usergroup is set to global persist dir, if not then set
function persist_permission($manifest, $global) {
    if($global -and $manifest.persist -and (is_admin)) {
        $path = persistdir $null $global
        $user = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        $target_rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'Write', 'ObjectInherit', 'none', 'Allow')
        $acl = Get-Acl -Path $path
        $acl.SetAccessRule($target_rule)
        $acl | Set-Acl -Path $path
    }
}
