Option Explicit
Dim shell, fileSystem, scriptDirectory, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & scriptDirectory & "\NowPlayingClipboard.ps1" & Chr(34) & " -HideConsole"
If WScript.Arguments.Count = 1 Then
    command = command & " " & WScript.Arguments(0)
End If
shell.Run command, 1, False
