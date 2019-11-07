. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\system.ps1"
. "$psscriptroot\Scoop-TestLib.ps1"

describe "ensure_robocopy_in_path" -Tag 'Scoop' {
    $shimdir = shimdir $false
    mock versiondir { $repo_dir }

    beforeall {
        reset_aliases
    }

    context "robocopy is not in path" {
        it "shims robocopy when not on path" -skip:$isUnix {
            mock Test-CommandAvailable { $false }
            Test-CommandAvailable robocopy | should -be $false

            ensure_robocopy_in_path

            "$shimdir/robocopy.ps1" | should -exist
            "$shimdir/robocopy.exe" | should -exist

            # clean up
            rm_shim robocopy $(shimdir $false) | out-null
        }
    }

    context "robocopy is in path" {
        it "does not shim robocopy when it is in path" -skip:$isUnix {
            mock Test-CommandAvailable { $true }
            Test-CommandAvailable robocopy | should -be $true

            ensure_robocopy_in_path

            "$shimdir/robocopy.ps1" | should -not -exist
            "$shimdir/robocopy.exe" | should -not -exist
        }
    }
}

describe "env add and remove path" -Tag 'Scoop' {
    # test data
    $manifest = @{
        "env_add_path" = @("foo", "bar")
    }
    $testdir = join-path $psscriptroot "path-test-directory"
    $global = $false

    # store the original path to prevent leakage of tests
    $origPath = $env:PATH

    it "should concat the correct path" -skip:$isUnix {
        mock add_first_in_path {}
        mock remove_from_path {}

        # adding
        env_add_path $manifest $testdir $global
        Assert-MockCalled add_first_in_path -Times 1 -ParameterFilter {$dir -like "$testdir\foo"}
        Assert-MockCalled add_first_in_path -Times 1 -ParameterFilter {$dir -like "$testdir\bar"}

        env_rm_path $manifest $testdir $global
        Assert-MockCalled remove_from_path -Times 1 -ParameterFilter {$dir -like "$testdir\foo"}
        Assert-MockCalled remove_from_path -Times 1 -ParameterFilter {$dir -like "$testdir\bar"}
    }
}
