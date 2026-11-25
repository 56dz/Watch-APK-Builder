Get-Process | Where-Object { $_.Path -like '*Android-Watch-APK-Build*' } | ForEach-Object { Write-Output ("stop " + $_.Name + " " + $_.Id); Stop-Process -Id $_.Id -Force }
