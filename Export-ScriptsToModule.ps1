﻿function Export-ScriptsToModule {
    <#
    .SYNOPSIS
        Function for generating Powershell module from ps1 scripts (that contains definition of functions) that are stored in given folder.
        Generated module will also contain function aliases (no matter if they are defined using Set-Alias or [Alias("Some-Alias")].
        Every script file has to have exactly same name as function that is defined inside it (ie Get-LoggedUsers.ps1 contains just function Get-LoggedUsers).
        If folder with ps1 script(s) contains also module manifest (psd1 file), it will be added as manifest of the generated module.
        In console where you call this function, font that can show UTF8 chars has to be set.

    .PARAMETER configHash
        Hash in specific format, where key is path to folder with scripts and value is path to which module should be generated.

        eg.: @{"C:\temp\scripts" = "C:\temp\Modules\Scripts"}

    .PARAMETER enc
        Which encoding should be used.

        Default is UTF8.

    .PARAMETER includeUncommitedUntracked
        Export also functions from modified-and-uncommited and untracked files.
        And use modified-and-untracked module manifest if necessary.

    .PARAMETER dontCheckSyntax
        Switch that will disable syntax checking of created module.

    .PARAMETER dontIncludeRequires
        Switch that will lead to ignoring all #requires in scripts, so generated module won't contain them.
        Otherwise just module #requires will be added.

    .PARAMETER markAutoGenerated
        Switch will add comment '# _AUTO_GENERATED_' on first line of each module, that was created by this function.
        For internal use, so I can distinguish which modules was created from functions stored in scripts2module and therefore easily generate various reports.

    .EXAMPLE
        Export-ScriptsToModule @{"C:\DATA\POWERSHELL\repo\scripts" = "c:\DATA\POWERSHELL\repo\modules\Scripts"}

    .NOTES
        Author: Ondřej Šebela - ztrhgf@seznam.cz
    #>

    [CmdletBinding()]
    param (
        [ValidateNotNullOrEmpty()]
        [hashtable] $configHash
        ,
        [ValidateNotNullOrEmpty()]
        [string] $enc = 'utf8'
        ,
        [switch] $includeUncommitedUntracked
        ,
        [switch] $dontCheckSyntax
        ,
        [switch] $dontIncludeRequires
        ,
        [switch] $markAutoGenerated
    )

    if (!(Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) -and !$dontCheckSyntax) {
        Write-Warning "Syntax won't be checked, because function Invoke-ScriptAnalyzer is not available (part of module PSScriptAnalyzer)"
    }
    function _generatePSModule {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $scriptFolder
            ,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $moduleFolder
            ,
            [switch] $includeUncommitedUntracked
        )

        if (!(Test-Path $scriptFolder)) {
            throw "Path $scriptFolder is not accessible"
        }

        $moduleName = Split-Path $moduleFolder -Leaf
        $modulePath = Join-Path $moduleFolder "$moduleName.psm1"
        $function2Export = @()
        $alias2Export = @()
        # contains function that will be exported to the module
        # the key is name of the function and value is its text definition
        $lastCommitFileContent = @{ }
        $location = Get-Location
        Set-Location $scriptFolder
        $unfinishedFile = @()
        try {
            # uncommited changed files
            $unfinishedFile += @(git ls-files -m --full-name)
            # untracked files
            $unfinishedFile += @(git ls-files --others --exclude-standard --full-name)
        } catch {
            throw "It seems GIT isn't installed. I was unable to get list of changed files in repository $scriptFolder"
        }
        Set-Location $location

        #region get last commited content of the modified untracked or uncommited files
        if ($unfinishedFile) {
            # there are untracked and/or uncommited files
            # instead just ignoring them try to get and use previous version from GIT
            [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)

            # helper function to be able to catch errors and all outputs
            # dont wait for exit
            function _startProcess {
                [CmdletBinding()]
                param (
                    [string] $filePath = 'notepad.exe',
                    [string] $argumentList = '/c dir',
                    [string] $workingDirectory = (Get-Location)
                )

                $p = New-Object System.Diagnostics.Process
                $p.StartInfo.UseShellExecute = $false
                $p.StartInfo.RedirectStandardOutput = $true
                $p.StartInfo.RedirectStandardError = $true
                $p.StartInfo.WorkingDirectory = $workingDirectory
                $p.StartInfo.FileName = $filePath
                $p.StartInfo.Arguments = $argumentList
                [void]$p.Start()
                # $p.WaitForExit() # cannot be used otherwise if git show HEAD:$file returned something, process stuck
                $p.StandardOutput.ReadToEnd()
                if ($err = $p.StandardError.ReadToEnd()) {
                    Write-Error $err
                }
            }

            $unfinishedScriptFile = $unfinishedFile.Clone() | ? { $_ -like "*.ps1" }

            if (!$includeUncommitedUntracked) {
                Set-Location $scriptFolder

                $unfinishedScriptFile | % {
                    $file = $_
                    $lastCommitContent = $null
                    $fName = [System.IO.Path]::GetFileNameWithoutExtension($file)

                    try {
                        $lastCommitContent = _startProcess git "show HEAD:$file" -ErrorAction Stop
                    } catch {
                        Write-Verbose "GIT error: $_"
                    }

                    if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
                        Write-Warning "$fName has uncommited changes. Skipping, because no previous file version was found in GIT"
                    } else {
                        Write-Warning "$fName has uncommited changes. For module generating I will use content from its last commit"
                        $lastCommitFileContent.$fName = $lastCommitContent
                        $unfinishedFile.Remove($file)
                    }
                }

                Set-Location $location
            }

            # unix / replace by \
            $unfinishedFile = $unfinishedFile -replace "/", "\"

            $unfinishedScriptFileName = $unfinishedScriptFile | % { [System.IO.Path]::GetFileName($_) }

            if ($includeUncommitedUntracked -and $unfinishedScriptFileName) {
                Write-Warning "Exporting changed but uncommited/untracked functions: $($unfinishedScriptFileName -join ', ')"
                $unfinishedFile = @()
            }
        }
        #endregion get last commited content of the modified untracked or uncommited files

        # in ps1 files to export leave just these in consistent state
        $script2Export = (Get-ChildItem (Join-Path $scriptFolder "*.ps1") -File).FullName | where {
            $partName = ($_ -split "\\")[-2..-1] -join "\"
            if ($unfinishedFile -and $unfinishedFile -match [regex]::Escape($partName)) {
                return $false
            } else {
                return $true
            }
        }

        if (!$script2Export -and $lastCommitFileContent.Keys.Count -eq 0) {
            Write-Warning "In $scriptFolder there is none usable function to export to $moduleFolder. Exiting"
            return
        }

        #region cleanup old module folder
        if (Test-Path $modulePath -ErrorAction SilentlyContinue) {
            Write-Verbose "Removing $moduleFolder"
            Remove-Item $moduleFolder -Recurse -Confirm:$false -ErrorAction Stop
            Start-Sleep 1
            [Void][System.IO.Directory]::CreateDirectory($moduleFolder)
        }
        #endregion cleanup old module folder

        Write-Verbose "Functions from the '$scriptFolder' will be converted to module '$modulePath'"

        #region fill $lastCommitFileContent hash with functions content
        $script2Export | % {
            $script = $_
            $fName = [System.IO.Path]::GetFileNameWithoutExtension($script)
            if ($fName -match "\s+") {
                throw "File $script contains space in name which is nonsense. Name of file has to be same to the name of functions it defines and functions can't contain space in it's names."
            }

            # add function content only in case it isn't added already (to avoid overwrites)
            if (!$lastCommitFileContent.containsKey($fName)) {
                # check, that file contain just one function definition and nothing else
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)
                # just END block should exist
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    throw "File $script isn't in correct format. It has to contain just function definition (+ alias definition, comment or requires)!"
                }

                # get funtion definition
                $functionDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        # Class methods have a FunctionDefinitionAst under them as well, but we don't want them.
                        ($PSVersionTable.PSVersion.Major -lt 5 -or
                        $ast.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst])
                    }, $false)

                if ($functionDefinition.count -ne 1) {
                    throw "File $script doesn't contain any function or contain's more than one."
                }

                #TODO pouzivat pro jmeno funkce jeji skutecne jmeno misto nazvu souboru?.
                # $fName = $functionDefinition.name

                # use function definition obtained by AST to generating module
                # this way no possible dangerous content will be added
                $content = ""
                if (!$dontIncludeRequires) {
                    # adding module requires
                    $requiredModules = $ast.scriptRequirements.requiredModules.name
                    if ($requiredModules) {
                        $content += "#Requires -Modules $($requiredModules -join ',')`n`n"
                    }
                }
                # replace invalid chars for valid (en dash etc)
                $functionText = $functionDefinition.extent.text -replace [char]0x2013, "-" -replace [char]0x2014, "-"

                # add function text definition
                $content += $functionText

                # add aliases defined by Set-Alias
                $ast.EndBlock.Statements | ? { $_ -match "^\s*Set-Alias .+" } | % { $_.extent.text } | % {
                    $parts = $_ -split "\s+"

                    $content += "`n$_"

                    if ($_ -match "-na") {
                        # alias set by named parameter
                        # get parameter value
                        $i = 0
                        $parPosition
                        $parts | % {
                            if ($_ -match "-na") {
                                $parPosition = $i
                            }
                            ++$i
                        }

                        # save alias for later export
                        $alias2Export += $parts[$parPosition + 1]
                        Write-Verbose "- exporting alias: $($parts[$parPosition + 1])"
                    } else {
                        # alias set by positional parameter
                        # save alias for later export
                        $alias2Export += $parts[1]
                        Write-Verbose "- exporting alias: $($parts[1])"
                    }
                }

                # add aliases defined by [Alias("Some-Alias")]
                $innerAliasDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.AttributeAst]
                    }, $true) | ? { $_.parent.extent.text -match '^param' } | Select-Object -ExpandProperty PositionalArguments | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue # filter out aliases for function parameters

                if ($innerAliasDefinition) {
                    $innerAliasDefinition | % {
                        $alias2Export += $_
                        Write-Verbose "- exporting 'inner' alias: $_"
                    }
                }

                $lastCommitFileContent.$fName = $content
            }
        }
        #endregion fill $lastCommitFileContent hash with functions content

        if ($markAutoGenerated) {
            "# _AUTO_GENERATED_" | Out-File $modulePath $enc
            "" | Out-File $modulePath -Append $enc
        }

        #region save all functions content to the module file
        # store name of every function for later use in Export-ModuleMember
        $lastCommitFileContent.GetEnumerator() | Sort-Object Name | % {
            $fName = $_.Key
            $content = $_.Value

            Write-Verbose "- exporting function: $fName"
            $function2Export += $fName

            $content | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }
        #endregion save all functions content to the module file

        #region set what functions and aliases should be exported from module
        # explicit export is much faster than use *
        if (!$function2Export) {
            throw "There are none functions to export! Wrong path??"
        } else {
            if ($function2Export -match "#") {
                Remove-Item $modulePath -Recurse -Force -Confirm:$false
                throw "Exported function contains unnaproved character # in it's name. Module was removed."
            }

            $function2Export = $function2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -function $($function2Export -join ', ')" | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }

        if ($alias2Export) {
            if ($alias2Export -match "#") {
                Remove-Item $modulePath -Recurse -Force -Confirm:$false
                throw "Exported alias contains unapproved character # in it's name. Module was removed."
            }

            $alias2Export = $alias2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -alias $($alias2Export -join ', ')" | Out-File $modulePath -Append $enc
        }
        #endregion set what functions and aliases should be exported from module

        #region process module manifest (psd1) file
        $manifestFile = (Get-ChildItem (Join-Path $scriptFolder "*.psd1") -File).FullName

        if ($manifestFile) {
            if ($manifestFile.count -eq 1) {
                $partName = ($manifestFile -split "\\")[-2..-1] -join "\"
                if ($partName -in $unfinishedFile -and !$includeUncommitedUntracked) {
                    Write-Warning "Module manifest file '$manifestFile' is modified but not commited."

                    $choice = ""
                    while ($choice -notmatch "^[Y|N]$") {
                        $choice = Read-Host "Continue? (Y|N)"
                    }
                    if ($choice -eq "N") {
                        break
                    }
                }

                try {
                    Write-Verbose "Processing '$manifestFile' manifest file"
                    $manifestDataHash = Import-PowerShellDataFile $manifestFile -ErrorAction Stop
                } catch {
                    Write-Error "Unable to process manifest file '$manifestFile'.`n`n$_"
                }

                if ($manifestDataHash) {
                    # customize manifest data
                    Write-Verbose "Set manifest RootModule key"
                    $manifestDataHash.RootModule = "$moduleName.psm1"
                    Write-Verbose "Set manifest FunctionsToExport key"
                    $manifestDataHash.FunctionsToExport = $function2Export
                    Write-Verbose "Set manifest AliasesToExport key"
                    if ($alias2Export) {
                        $manifestDataHash.AliasesToExport = $alias2Export
                    } else {
                        $manifestDataHash.AliasesToExport = @()
                    }

                    # create final manifest file
                    Write-Verbose "Generating module manifest file"
                    # create empty one and than update it because of the bug https://github.com/PowerShell/PowerShell/issues/5922
                    New-ModuleManifest -Path (Join-Path $moduleFolder "$moduleName.psd1")
                    Update-ModuleManifest -Path (Join-Path $moduleFolder "$moduleName.psd1") @manifestDataHash
                    if ($manifestDataHash.PrivateData.PSData) {
                        # bugfix because PrivateData parameter expect content of PSData instead of PrivateData
                        Update-ModuleManifest -Path (Join-Path $moduleFolder "$moduleName.psd1") -PrivateData $manifestDataHash.PrivateData.PSData
                    }
                }
            } else {
                Write-Warning "Module manifest file won't be processed because more than one were found."
            }
        } else {
            Write-Verbose "No module manifest file found"
        }
        #endregion process module manifest (psd1) file
    } # end of _generatePSModule

    $configHash.GetEnumerator() | % {
        $scriptFolder = $_.key
        $moduleFolder = $_.value

        $param = @{
            scriptFolder = $scriptFolder
            moduleFolder = $moduleFolder
            verbose      = $VerbosePreference
        }
        if ($includeUncommitedUntracked) {
            $param["includeUncommitedUntracked"] = $true
        }

        _generatePSModule @param

        if (!$dontCheckSyntax -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            # check generated module syntax
            $syntaxError = Invoke-ScriptAnalyzer $moduleFolder -Severity Error
            if ($syntaxError) {
                Write-Warning "In module $moduleFolder was found these problems:"
                $syntaxError
            }
        }
    }
}
