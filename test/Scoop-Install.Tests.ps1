. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\manifest.ps1"
. "$psscriptroot\..\lib\install.ps1"
. "$psscriptroot\..\lib\unix.ps1"
. "$psscriptroot\Scoop-TestLib.ps1"

$isUnix = is_unix

describe "ensure_architecture" -Tag 'Scoop' {
    it "should keep correct architectures" {
        ensure_architecture "32bit" | should -be "32bit"
        ensure_architecture "32" | should -be "32bit"
        ensure_architecture "x86" | should -be "32bit"
        ensure_architecture "X86" | should -be "32bit"
        ensure_architecture "i386" | should -be "32bit"
        ensure_architecture "386" | should -be "32bit"
        ensure_architecture "i686" | should -be "32bit"

        ensure_architecture "64bit" | should -be "64bit"
        ensure_architecture "64" | should -be "64bit"
        ensure_architecture "x64" | should -be "64bit"
        ensure_architecture "X64" | should -be "64bit"
        ensure_architecture "amd64" | should -be "64bit"
        ensure_architecture "AMD64" | should -be "64bit"
        ensure_architecture "x86_64" | should -be "64bit"
        ensure_architecture "x86-64" | should -be "64bit"
    }

    it "should fallback to the default architecture on empty input" {
        ensure_architecture "" | should -be $(default_architecture)
        ensure_architecture $null | should -be $(default_architecture)
    }

    it "should show an error with an invalid architecture" {
        { ensure_architecture "PPC" } | Should -Throw
        { ensure_architecture "PPC" } | Should -Throw "Invalid architecture: 'ppc'"
    }
}

describe "appname_from_url" -Tag 'Scoop' {
    it "should extract the correct name" {
        appname_from_url "https://example.org/directory/foobar.json" | should -be "foobar"
    }
}

describe "url_filename" -Tag 'Scoop' {
    it "should extract the real filename from an url" {
        url_filename "http://example.org/foo.txt" | should -be "foo.txt"
        url_filename "http://example.org/foo.txt?var=123" | should -be "foo.txt"
    }

    it "can be tricked with a hash to override the real filename" {
        url_filename "http://example.org/foo-v2.zip#/foo.zip" | should -be "foo.zip"
    }
}

describe "url_remote_filename" -Tag 'Scoop' {
    it "should extract the real filename from an url" {
        url_remote_filename "http://example.org/foo.txt" | should -be "foo.txt"
        url_remote_filename "http://example.org/foo.txt?var=123" | should -be "foo.txt"
    }

    it "can not be tricked with a hash to override the real filename" {
        url_remote_filename "http://example.org/foo-v2.zip#/foo.zip" | should -be "foo-v2.zip"
    }
}

describe "is_in_dir" -Tag 'Scoop' {
    it "should work correctly" -skip:$isUnix {
        is_in_dir "C:\test" "C:\foo" | should -BeFalse
        is_in_dir "C:\test" "C:\test\foo\baz.zip" | should -betrue

        is_in_dir "test" "$psscriptroot" | should -betrue
        is_in_dir "$psscriptroot\..\" "$psscriptroot" | should -BeFalse
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

describe "shim_def" -Tag 'Scoop' {
    it "should use strings correctly" {
        $target, $name, $shimArgs = shim_def "command.exe"
        $target | should -be "command.exe"
        $name | should -be "command"
        $shimArgs | should -benullorempty
    }

    it "should expand the array correctly" {
        $target, $name, $shimArgs = shim_def @("foo.exe", "bar")
        $target | should -be "foo.exe"
        $name | should -be "bar"
        $shimArgs | should -benullorempty

        $target, $name, $shimArgs = shim_def @("foo.exe", "bar", "--test")
        $target | should -be "foo.exe"
        $name | should -be "bar"
        $shimArgs | should -be "--test"
    }
}

describe 'persist_def' -Tag 'Scoop' {
    it 'parses string correctly' {
        $source, $target = persist_def "test"
        $source | should -be "test"
        $target | should -be "test"
    }

    it 'should handle sub-folder' {
        $source, $target = persist_def "foo/bar"
        $source | should -be "foo/bar"
        $target | should -be "foo/bar"
    }

    it 'should handle arrays' {
        # both specified
        $source, $target = persist_def @("foo", "bar")
        $source | should -be "foo"
        $target | should -be "bar"

        # only first specified
        $source, $target = persist_def @("foo")
        $source | should -be "foo"
        $target | should -be "foo"

        # null value specified
        $source, $target = persist_def @("foo", $null)
        $source | should -be "foo"
        $target | should -be "foo"
    }
}
