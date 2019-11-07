. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\download.ps1"
. "$psscriptroot\Scoop-TestLib.ps1"

describe 'compute_hash' -Tag 'Scoop' {
    beforeall {
        $working_dir = setup_working "manifest"
    }

    it 'computes MD5 correctly' {
        compute_hash (join-path "$working_dir" "invalid_wget.json") 'md5' | should -be "cf229eecc201063e32b436e73b71deba"
        compute_hash (join-path "$working_dir" "wget.json") 'md5' | should -be "57c397fd5092cbd6a8b4df56be2551ab"
        compute_hash (join-path "$working_dir" "broken_schema.json") 'md5' | should -be "0427c7f4edc33d6d336db98fc160beb0"
        compute_hash (join-path "$working_dir" "broken_wget.json") 'md5' | should -be "30a7d4d3f64cb7a800d96c0f2ccec87f"
    }

    it 'computes SHA-1 correctly' {
        compute_hash (join-path "$working_dir" "invalid_wget.json") 'sha1' | should -be "33ae44df8feed86cdc8f544234029fb28280c3c5"
        compute_hash (join-path "$working_dir" "wget.json") 'sha1' | should -be "98bfacb887da8cd05d3a1162f89d90173294be55"
        compute_hash (join-path "$working_dir" "broken_schema.json") 'sha1' | should -be "6dcd64f8ce7a3ae6bbc3dc2288b7cb202dbfa3c8"
        compute_hash (join-path "$working_dir" "broken_wget.json") 'sha1' | should -be "60b5b1d5bcb4193d19aeab265eab0bb9b0c46c8f"
    }

    it 'computes SHA-256 correctly' {
        compute_hash (join-path "$working_dir" "invalid_wget.json") 'sha256' | should -be "1a92ef57c5f3cecba74015ae8e92fc3f2dbe141f9d171c3a06f98645a522d58c"
        compute_hash (join-path "$working_dir" "wget.json") 'sha256' | should -be "31d6d0953d4e95f0a42080acd61a8c2f92bc90cae324c0d6d2301a974c15f62f"
        compute_hash (join-path "$working_dir" "broken_schema.json") 'sha256' | should -be "f3e5082e366006c317d9426e590623254cb1ce23d4f70165afed340b03ce333b"
        compute_hash (join-path "$working_dir" "broken_wget.json") 'sha256' | should -be "da658987c3902658c6e754bfa6546dfd084aaa2c3ae25f1fd8aa4645bc9cae24"
    }

    it 'computes SHA-512 correctly' {
        compute_hash (join-path "$working_dir" "invalid_wget.json") 'sha512' | should -be "7a7b82ec17547f5ec13dc614a8cec919e897e6c344a6ce7d71205d6f1c3aed276c7b15cbc69acac8207f72417993299cef36884e1915d56758ea09efa2259870"
        compute_hash (join-path "$working_dir" "wget.json") 'sha512' | should -be "216ebf07bb77062b51420f0f5eb6b7a94d9623d1d41d36c833436058f41e39898f2aa48d7020711c0d8765d02b87ac2e6810f3f502636a6e6f47dc4b9aa02d17"
        compute_hash (join-path "$working_dir" "broken_schema.json") 'sha512' | should -be "8d3f5617517e61c33275eafea4b166f0a245ec229c40dea436173c354786bad72e4fd9d662f6ac2b9f3dd375c00815a07f10e12975eec1b12da7ba7db10f9c14"
        compute_hash (join-path "$working_dir" "broken_wget.json") 'sha512' | should -be "7b16a714491e91cc6daa5f90e700547fac4d62e1fcec8c4b78f5a2386e04e68a8ed68f27503ece9555904a047df8050b3f12b4f779c05b1e4d0156e6e2d8fdbb"
    }
}
