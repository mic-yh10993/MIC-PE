BeforeAll {
    $root = "$PSScriptRoot/.."
}

Describe 'installer assets' {
    It 'wcs exists and declares the auto switch' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match '-auto'
        $w | Should -Match 'install\.mic'
    }

    It 'wcs opens DiskGenius for the partition button' {
        (Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw) | Should -Match 'DiskGenius\.exe'
    }

    It 'wcs offers the two unattend templates and is opt-in' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'Win10_x64\.xml'
        $w | Should -Match 'Win7-11-Select\.xml'
        $w | Should -Match '无人值守\.Check=0'
    }

    It 'PECMD.INI launches the installer only when a source was found' {
        $p = Get-Content "$root/src/shell/PECMD.INI" -Raw
        $p | Should -Match 'MICPE-Setup'
        $p | Should -Match 'IFEX'
    }

    It 'ini points logs and DiskGenius at the MICPE paths' {
        $i = Get-Content "$root/src/installer/MICPE-Setup.ini" -Raw
        $i | Should -Match 'LogDir=X:\\Program Files\\MICPE\\logs'
        $i | Should -Match 'DiskGenius=X:\\Program Files\\DiskGenius\.exe'
    }

    It 'wcs declares the cli discover and deploy modes for the probe' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match '-cli'
        $w | Should -Match '-discoveronly'
        $w | Should -Match '-deploy'
        $w | Should -Match 'installer_scan=1'
        $w | Should -Match 'installer_deploy=1'
    }

    It 'wcs checks target safety before deploying' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'CheckTarget'
        $w | Should -Match 'format\.com'
        $w | Should -Match 'bcdboot'
    }

    It 'wcs is a single 760x520 window per the spec layout' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match '@this\.W=760'
        $w | Should -Match '@this\.H=520'
        $w | Should -Match '开始安装'
    }

    It 'wcs reports a marker volume with a missing image instead of falling through' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'BrokenSources'
        $w | Should -Match '标记存在但映像缺失'
    }

    It 'wcs writes the source path and the real source kind for the deploy step' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'installer_path=%Source1_Path%'
        $w | Should -Match 'installer_source=marker'
        $w | Should -Match 'installer_source=fallback'
        $w | Should -Match 'Source1_Marker'
    }

    It 'wcs resolves the default index in cli deploy mode (no dropdown there)' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'Select-DefaultIndex'
        $w | Should -Match 'verindex\.txt'
        $w | Should -Match 'READ %SystemDrive%\\verindex\.txt,1,VerIndex'
    }

    It 'wcs defaults the boot drive to the target drive before bcdboot' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'IFEX %BootDrive%=,ENVI BootDrive=%TargetDrive%'
    }

    It 'lang file carries the same user-visible strings as the wcs' {
        $lang = Get-Content "$root/src/installer/lang/zh-CN.txt" -Raw
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        foreach ($s in 'MICPE 一键装机', '更换镜像', '重新扫描', '分区', '开始安装') {
            $lang | Should -Match ([regex]::Escape($s)) -Because "lang must carry $s"
            $w | Should -Match ([regex]::Escape($s)) -Because "wcs must show $s"
        }
    }

    It 'PECMD.INI scans for a source only after probe.cmd has run' {
        $p = Get-Content "$root/src/shell/PECMD.INI" -Raw
        $p.IndexOf('probe.cmd') | Should -BeLessThan $p.IndexOf('MICPE-Setup.wcs')
        $p | Should -Match 'MICPE_SETUP_LAUNCHED'
    }
}
