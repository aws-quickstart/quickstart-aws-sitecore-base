#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

[CmdletBinding()]
param (
    [string]
    $pathToZips = '/c/temp'
)
$zips = Get-ChildItem -Path $pathToZips -Recurse -ErrorAction SilentlyContinue -Filter *.zip |
    Where-Object { $_.Extension -eq '.zip' }

foreach ($zipfile in $zips) {
    $zipfileName = $zipfile.FullName
    $fileExtension = 'sql'
    Write-Output "Editing $($Zipfile.FullName)"
    $searchString = "exec sp_configure 'contained database authentication', 1
go
reconfigure
go"

    Add-Type -assembly  System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipfileName, "Update")
    $filesToEdit = $zip.Entries.Where( { $_.name -like "*.$fileExtension" })

    foreach ($file in $filesToEdit) {
        Write-Output "Inspecting $($file.name)"
        $robotsFile = $zip.Entries.Where( { $_.name -eq $file.name })
        # Update the contents of the file
        $desiredFile = [System.IO.StreamReader]($robotsFile[0]).Open()
        $text = $desiredFile.ReadToEnd()
        $NewText = $text.ToString() -replace $searchString, ''
        $desiredFile.Close()
        $desiredFile.Dispose()
        if (Compare-Object $text $NewText) {
            Write-Output "Updating $($file.name)"
            $desiredFile = [System.IO.StreamWriter]($robotsFile).Open()
            $desiredFile.BaseStream.SetLength(0)
            $desiredFile.Write($NewText)
            $desiredFile.Flush()
            $desiredFile.Close()
        }
    }
    # Write the changes and close the zip file
    Write-Output "Done with $Zipfile.FullName"
    $zip.Dispose()

}