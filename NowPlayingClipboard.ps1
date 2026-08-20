[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$HideConsole
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogDirectory = Join-Path $script:AppDirectory 'logs'
$script:LogFile = Join-Path $script:LogDirectory 'now-playing.log'
$script:SettingsFile = Join-Path $script:AppDirectory 'settings.json'
$script:SessionManagerType = $null
$script:MediaPropertiesType = $null

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
            New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Add-Content -LiteralPath $script:LogFile -Value "$timestamp [$Level] $Message" -Encoding UTF8
    }
    catch {
        # ログ出力の失敗で本処理を止めない
    }
}

function Hide-ConsoleWindow {
    if (-not ('NowPlayingConsoleWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NowPlayingConsoleWindow
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    public static void Hide()
    {
        IntPtr windowHandle = GetConsoleWindow();
        if (windowHandle != IntPtr.Zero)
        {
            ShowWindow(windowHandle, 0);
        }
    }
}
'@
    }

    [NowPlayingConsoleWindow]::Hide()
}

function Get-WindowsDarkMode {
    try {
        $personalizePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $value = Get-ItemPropertyValue -Path $personalizePath -Name 'AppsUseLightTheme' -ErrorAction Stop
        return [int]$value -eq 0
    }
    catch {
        return $false
    }
}

function Get-SavedThemeMode {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) {
        return 'System'
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($settings.ThemeMode -in @('System', 'Light', 'Dark')) {
            return [string]$settings.ThemeMode
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message "テーマ設定を読み込めませんでした: $($_.Exception.Message)"
    }

    return 'System'
}

function Save-ThemeMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('System', 'Light', 'Dark')]
        [string]$ThemeMode
    )

    try {
        $settings = [PSCustomObject]@{
            ThemeMode = $ThemeMode
        }
        $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    }
    catch {
        Write-AppLog -Level 'WARN' -Message "テーマ設定を保存できませんでした: $($_.Exception.Message)"
    }
}

function Set-DarkTitleBar {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$WindowHandle,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    if (-not ('NowPlayingWindowTheme' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NowPlayingWindowTheme
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr windowHandle,
        int attribute,
        ref int attributeValue,
        int attributeSize);

    public static void SetDarkTitleBar(IntPtr windowHandle, bool enabled)
    {
        if (windowHandle == IntPtr.Zero)
        {
            return;
        }

        int value = enabled ? 1 : 0;
        int result = DwmSetWindowAttribute(windowHandle, 20, ref value, sizeof(int));
        if (result != 0)
        {
            DwmSetWindowAttribute(windowHandle, 19, ref value, sizeof(int));
        }
    }
}
'@
    }

    try {
        [NowPlayingWindowTheme]::SetDarkTitleBar($WindowHandle, $Enabled)
    }
    catch {
        Write-AppLog -Level 'WARN' -Message "タイトルバーのテーマを変更できませんでした: $($_.Exception.Message)"
    }
}

function Initialize-WindowsRuntime {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime

    $script:SessionManagerType = [type]::GetType(
        'Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows, ContentType=WindowsRuntime'
    )
    $script:MediaPropertiesType = [type]::GetType(
        'Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows, ContentType=WindowsRuntime'
    )

    if ($null -eq $script:SessionManagerType -or $null -eq $script:MediaPropertiesType) {
        throw 'Windowsのメディア情報APIを読み込めませんでした。Windows 10/11で実行してください。'
    }
}

function Wait-WindowsRuntimeOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][type]$ResultType
    )

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if ($null -eq $asTaskMethod) {
        throw 'Windows Runtimeの非同期処理を初期化できませんでした。'
    }

    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Get-NowPlaying {
    if ($null -eq $script:SessionManagerType) {
        Initialize-WindowsRuntime
    }

    $manager = Wait-WindowsRuntimeOperation `
        -Operation ($script:SessionManagerType::RequestAsync()) `
        -ResultType $script:SessionManagerType

    $sessions = @($manager.GetSessions())
    if ($sessions.Count -eq 0) {
        throw '再生中のメディアが見つかりません。音楽を再生してから「更新」を押してください。'
    }

    # 再生中のセッションを優先し、複数ある場合はWindowsが選ぶ現在のセッションを優先する
    $currentSession = $manager.GetCurrentSession()
    $playingSessions = @($sessions | Where-Object {
        $_.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing'
    })

    $selectedSession = $null
    if ($null -ne $currentSession -and $currentSession.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') {
        $selectedSession = $currentSession
    }
    elseif ($playingSessions.Count -gt 0) {
        $selectedSession = $playingSessions[0]
    }
    elseif ($null -ne $currentSession) {
        $selectedSession = $currentSession
    }
    else {
        $selectedSession = $sessions[0]
    }

    $properties = Wait-WindowsRuntimeOperation `
        -Operation ($selectedSession.TryGetMediaPropertiesAsync()) `
        -ResultType $script:MediaPropertiesType

    $title = [string]$properties.Title
    $artist = [string]$properties.Artist
    $album = [string]$properties.AlbumTitle

    if ([string]::IsNullOrWhiteSpace($artist)) {
        $artist = [string]$properties.AlbumArtist
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        throw '曲名を取得できませんでした。プレイヤー側のメディア表示を確認してください。'
    }

    return [PSCustomObject]@{
        Title     = $title.Trim()
        Artist    = $artist.Trim()
        Album     = $album.Trim()
        SourceApp = [string]$selectedSession.SourceAppUserModelId
        Status    = $selectedSession.GetPlaybackInfo().PlaybackStatus.ToString()
    }
}

function Format-PostText {
    param(
        [Parameter(Mandatory = $true)]$Media
    )

    if ([string]::IsNullOrWhiteSpace($Media.Artist)) {
        return "$($Media.Title) #NowPlaying"
    }

    return "$($Media.Title) / $($Media.Artist) #NowPlaying"
}

function Get-NowPlayingThumbnail {
    $thumbnailFetcher = Join-Path $script:AppDirectory 'ThumbnailFetcher.exe'
    $dotnetPath = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'

    if (-not (Test-Path -LiteralPath $dotnetPath) -or -not (Test-Path -LiteralPath $thumbnailFetcher)) {
        Write-AppLog -Level 'WARN' -Message 'サムネイル取得に必要な.NETランタイムまたは補助プログラムが見つかりません。'
        return $null
    }

    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("NowPlayingClipboard-{0}.image" -f ([guid]::NewGuid().ToString('N')))

    try {
        & $dotnetPath $thumbnailFetcher $temporaryPath 2>$null
        $thumbnailExitCode = $LASTEXITCODE

        if ($thumbnailExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPath)) {
            return $null
        }

        $fileStream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $sourceImage = [System.Drawing.Image]::FromStream($fileStream)
            try {
                # 元ストリームを閉じても表示・保存できる独立したBitmapに複製する
                return [System.Drawing.Bitmap]::new($sourceImage)
            }
            finally {
                $sourceImage.Dispose()
            }
        }
        finally {
            $fileStream.Dispose()
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message "サムネイルを取得できませんでした: $($_.Exception.Message)"
        return $null
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-ClipboardWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Text
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 150
        }
    }

    throw "クリップボードにコピーできませんでした: $($lastError.Exception.Message)"
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'なうぷれコピー'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(760, 590)
    $form.MinimumSize = New-Object System.Drawing.Size(790, 629)
    $form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 10)
    $form.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(24, 22)
    $titleLabel.Size = New-Object System.Drawing.Size(540, 32)
    $titleLabel.Font = New-Object System.Drawing.Font('Yu Gothic UI', 17, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = '再生中の曲をXへ'
    $form.Controls.Add($titleLabel)

    $descriptionLabel = New-Object System.Windows.Forms.Label
    $descriptionLabel.Location = New-Object System.Drawing.Point(26, 60)
    $descriptionLabel.Size = New-Object System.Drawing.Size(710, 24)
    $descriptionLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 112)
    $descriptionLabel.Text = '曲情報を取得し、投稿用テキストをクリップボードへコピーします。'
    $form.Controls.Add($descriptionLabel)

    $themeButton = New-Object System.Windows.Forms.Button
    $themeButton.Location = New-Object System.Drawing.Point(590, 20)
    $themeButton.Size = New-Object System.Drawing.Size(140, 36)
    $themeButton.Anchor = 'Top, Right'
    $themeButton.FlatStyle = 'Flat'
    $themeButton.UseVisualStyleBackColor = $false
    $form.Controls.Add($themeButton)

    $songCaption = New-Object System.Windows.Forms.Label
    $songCaption.Location = New-Object System.Drawing.Point(242, 103)
    $songCaption.Size = New-Object System.Drawing.Size(100, 23)
    $songCaption.Text = '曲名'
    $form.Controls.Add($songCaption)

    $songValue = New-Object System.Windows.Forms.TextBox
    $songValue.Location = New-Object System.Drawing.Point(242, 129)
    $songValue.Size = New-Object System.Drawing.Size(488, 29)
    $songValue.ReadOnly = $true
    $songValue.BackColor = [System.Drawing.Color]::White
    $songValue.Anchor = 'Top, Left, Right'
    $form.Controls.Add($songValue)

    $artistCaption = New-Object System.Windows.Forms.Label
    $artistCaption.Location = New-Object System.Drawing.Point(242, 172)
    $artistCaption.Size = New-Object System.Drawing.Size(100, 23)
    $artistCaption.Text = 'アーティスト'
    $form.Controls.Add($artistCaption)

    $artistValue = New-Object System.Windows.Forms.TextBox
    $artistValue.Location = New-Object System.Drawing.Point(242, 198)
    $artistValue.Size = New-Object System.Drawing.Size(488, 29)
    $artistValue.ReadOnly = $true
    $artistValue.BackColor = [System.Drawing.Color]::White
    $artistValue.Anchor = 'Top, Left, Right'
    $form.Controls.Add($artistValue)

    $albumCaption = New-Object System.Windows.Forms.Label
    $albumCaption.Location = New-Object System.Drawing.Point(242, 241)
    $albumCaption.Size = New-Object System.Drawing.Size(100, 23)
    $albumCaption.Text = 'アルバム'
    $form.Controls.Add($albumCaption)

    $albumValue = New-Object System.Windows.Forms.TextBox
    $albumValue.Location = New-Object System.Drawing.Point(242, 267)
    $albumValue.Size = New-Object System.Drawing.Size(488, 29)
    $albumValue.ReadOnly = $true
    $albumValue.BackColor = [System.Drawing.Color]::White
    $albumValue.Anchor = 'Top, Left, Right'
    $form.Controls.Add($albumValue)

    $postCaption = New-Object System.Windows.Forms.Label
    $thumbnailBox = New-Object System.Windows.Forms.PictureBox
    $thumbnailBox.Location = New-Object System.Drawing.Point(28, 99)
    $thumbnailBox.Size = New-Object System.Drawing.Size(190, 190)
    $thumbnailBox.SizeMode = 'Zoom'
    $thumbnailBox.BackColor = [System.Drawing.Color]::FromArgb(226, 231, 238)
    $thumbnailBox.BorderStyle = 'FixedSingle'
    $form.Controls.Add($thumbnailBox)

    $copyImageButton = New-Object System.Windows.Forms.Button
    $copyImageButton.Location = New-Object System.Drawing.Point(28, 300)
    $copyImageButton.Size = New-Object System.Drawing.Size(91, 34)
    $copyImageButton.Text = '画像コピー'
    $copyImageButton.Enabled = $false
    $form.Controls.Add($copyImageButton)

    $saveImageButton = New-Object System.Windows.Forms.Button
    $saveImageButton.Location = New-Object System.Drawing.Point(127, 300)
    $saveImageButton.Size = New-Object System.Drawing.Size(91, 34)
    $saveImageButton.Text = 'PNG保存'
    $saveImageButton.Enabled = $false
    $form.Controls.Add($saveImageButton)

    $postCaption.Location = New-Object System.Drawing.Point(26, 355)
    $postCaption.Size = New-Object System.Drawing.Size(260, 23)
    $postCaption.Text = '投稿内容（編集できます）'
    $form.Controls.Add($postCaption)

    $characterLabel = New-Object System.Windows.Forms.Label
    $characterLabel.Location = New-Object System.Drawing.Point(614, 355)
    $characterLabel.Size = New-Object System.Drawing.Size(116, 23)
    $characterLabel.TextAlign = 'MiddleRight'
    $characterLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 112)
    $characterLabel.Anchor = 'Top, Right'
    $characterLabel.Text = '0 / 280文字'
    $form.Controls.Add($characterLabel)

    $postText = New-Object System.Windows.Forms.TextBox
    $postText.Location = New-Object System.Drawing.Point(28, 384)
    $postText.Size = New-Object System.Drawing.Size(702, 72)
    $postText.Multiline = $true
    $postText.ScrollBars = 'Vertical'
    $postText.Anchor = 'Top, Left, Right'
    $form.Controls.Add($postText)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(28, 467)
    $statusLabel.Size = New-Object System.Drawing.Size(702, 25)
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 90, 102)
    $statusLabel.Anchor = 'Top, Left, Right'
    $statusLabel.Text = '曲情報を取得しています…'
    $form.Controls.Add($statusLabel)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Location = New-Object System.Drawing.Point(28, 515)
    $refreshButton.Size = New-Object System.Drawing.Size(132, 42)
    $refreshButton.Text = '更新'
    $refreshButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($refreshButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Location = New-Object System.Drawing.Point(173, 515)
    $copyButton.Size = New-Object System.Drawing.Size(222, 42)
    $copyButton.Text = 'クリップボードへコピー'
    $copyButton.BackColor = [System.Drawing.Color]::FromArgb(29, 155, 240)
    $copyButton.ForeColor = [System.Drawing.Color]::White
    $copyButton.FlatStyle = 'Flat'
    $copyButton.FlatAppearance.BorderSize = 0
    $copyButton.Anchor = 'Bottom, Left'
    $copyButton.Enabled = $false
    $form.Controls.Add($copyButton)

    $openXButton = New-Object System.Windows.Forms.Button
    $openXButton.Location = New-Object System.Drawing.Point(408, 515)
    $openXButton.Size = New-Object System.Drawing.Size(322, 42)
    $openXButton.Text = 'コピーしてXの投稿画面を開く'
    $openXButton.Anchor = 'Bottom, Left, Right'
    $openXButton.Enabled = $false
    $form.Controls.Add($openXButton)

    $state = [PSCustomObject]@{
        Thumbnail = $null
        ThemeMode = Get-SavedThemeMode
        IsDark    = $false
    }

    $applyTheme = {
        $state.IsDark = switch ($state.ThemeMode) {
            'Dark'  { $true }
            'Light' { $false }
            default { Get-WindowsDarkMode }
        }

        if ($state.IsDark) {
            $backgroundColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
            $surfaceColor = [System.Drawing.Color]::FromArgb(30, 33, 39)
            $buttonColor = [System.Drawing.Color]::FromArgb(42, 46, 54)
            $primaryTextColor = [System.Drawing.Color]::FromArgb(238, 241, 245)
            $secondaryTextColor = [System.Drawing.Color]::FromArgb(161, 171, 185)
            $borderColor = [System.Drawing.Color]::FromArgb(67, 73, 84)
            $warningColor = [System.Drawing.Color]::FromArgb(255, 112, 112)
            $thumbnailColor = [System.Drawing.Color]::FromArgb(25, 28, 33)
        }
        else {
            $backgroundColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
            $surfaceColor = [System.Drawing.Color]::White
            $buttonColor = [System.Drawing.Color]::FromArgb(238, 241, 245)
            $primaryTextColor = [System.Drawing.Color]::FromArgb(28, 33, 40)
            $secondaryTextColor = [System.Drawing.Color]::FromArgb(90, 99, 112)
            $borderColor = [System.Drawing.Color]::FromArgb(190, 197, 207)
            $warningColor = [System.Drawing.Color]::Firebrick
            $thumbnailColor = [System.Drawing.Color]::FromArgb(226, 231, 238)
        }

        $form.SuspendLayout()
        try {
            $form.BackColor = $backgroundColor
            $form.ForeColor = $primaryTextColor

            foreach ($label in @($titleLabel, $songCaption, $artistCaption, $albumCaption, $postCaption)) {
                $label.ForeColor = $primaryTextColor
            }
            foreach ($label in @($descriptionLabel, $statusLabel)) {
                $label.ForeColor = $secondaryTextColor
            }
            foreach ($textBox in @($songValue, $artistValue, $albumValue, $postText)) {
                $textBox.BackColor = $surfaceColor
                $textBox.ForeColor = $primaryTextColor
                $textBox.BorderStyle = 'FixedSingle'
            }

            $thumbnailBox.BackColor = $thumbnailColor

            foreach ($button in @($themeButton, $refreshButton, $copyImageButton, $saveImageButton, $openXButton)) {
                $button.UseVisualStyleBackColor = $false
                $button.FlatStyle = 'Flat'
                $button.FlatAppearance.BorderSize = 1
                $button.FlatAppearance.BorderColor = $borderColor
                $button.BackColor = $buttonColor
                $button.ForeColor = $primaryTextColor
            }

            $copyButton.UseVisualStyleBackColor = $false
            $copyButton.BackColor = [System.Drawing.Color]::FromArgb(29, 155, 240)
            $copyButton.ForeColor = [System.Drawing.Color]::White

            if ($postText.Text.Length -gt 280) {
                $characterLabel.ForeColor = $warningColor
            }
            else {
                $characterLabel.ForeColor = $secondaryTextColor
            }

            switch ($state.ThemeMode) {
                'Dark'  { $themeButton.Text = 'テーマ：ダーク' }
                'Light' { $themeButton.Text = 'テーマ：ライト' }
                default {
                    if ($state.IsDark) {
                        $themeButton.Text = 'テーマ：自動（暗）'
                    }
                    else {
                        $themeButton.Text = 'テーマ：自動（明）'
                    }
                }
            }

            if ($form.IsHandleCreated) {
                Set-DarkTitleBar -WindowHandle $form.Handle -Enabled $state.IsDark
            }
            $form.Invalidate($true)
        }
        finally {
            $form.ResumeLayout($true)
        }
    }

    $updateCharacterCount = {
        $count = $postText.Text.Length
        $characterLabel.Text = "$count / 280文字"
        if ($count -gt 280) {
            if ($state.IsDark) {
                $characterLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 112, 112)
            }
            else {
                $characterLabel.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }
        else {
            if ($state.IsDark) {
                $characterLabel.ForeColor = [System.Drawing.Color]::FromArgb(161, 171, 185)
            }
            else {
                $characterLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 112)
            }
        }
        $hasText = -not [string]::IsNullOrWhiteSpace($postText.Text)
        $copyButton.Enabled = $hasText
        $openXButton.Enabled = $hasText
    }

    $loadMedia = {
        $refreshButton.Enabled = $false
        $statusLabel.Text = '曲情報を取得しています…'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $media = Get-NowPlaying
            $songValue.Text = $media.Title
            $artistValue.Text = $media.Artist
            $albumValue.Text = $media.Album
            $postText.Text = Format-PostText -Media $media

            if ($null -ne $state.Thumbnail) {
                $thumbnailBox.Image = $null
                $state.Thumbnail.Dispose()
                $state.Thumbnail = $null
            }

            $state.Thumbnail = Get-NowPlayingThumbnail
            $thumbnailBox.Image = $state.Thumbnail
            $hasThumbnail = $null -ne $state.Thumbnail
            $copyImageButton.Enabled = $hasThumbnail
            $saveImageButton.Enabled = $hasThumbnail

            if ($hasThumbnail) {
                $statusLabel.Text = "取得元: $($media.SourceApp) / サムネイル: $($state.Thumbnail.Width)×$($state.Thumbnail.Height)"
            }
            else {
                $statusLabel.Text = "取得元: $($media.SourceApp) / サムネイルは提供されていません"
            }
        }
        catch {
            $songValue.Clear()
            $artistValue.Clear()
            $albumValue.Clear()
            $postText.Clear()
            $copyImageButton.Enabled = $false
            $saveImageButton.Enabled = $false
            $statusLabel.Text = $_.Exception.Message
            Write-AppLog -Level 'ERROR' -Message $_.Exception.ToString()
        }
        finally {
            $refreshButton.Enabled = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $copyText = {
        try {
            Set-ClipboardWithRetry -Text $postText.Text
            $statusLabel.Text = 'コピーしました。Xに貼り付けて投稿できます。'
        }
        catch {
            $statusLabel.Text = $_.Exception.Message
            Write-AppLog -Level 'ERROR' -Message $_.Exception.ToString()
            throw
        }
    }

    $copyImageButton.Add_Click({
        try {
            if ($null -eq $state.Thumbnail) {
                throw 'コピーできるサムネイルがありません。'
            }
            [System.Windows.Forms.Clipboard]::SetImage($state.Thumbnail)
            $statusLabel.Text = 'サムネイル画像をクリップボードへコピーしました。'
        }
        catch {
            $statusLabel.Text = $_.Exception.Message
            Write-AppLog -Level 'ERROR' -Message $_.Exception.ToString()
        }
    })
    $saveImageButton.Add_Click({
        try {
            if ($null -eq $state.Thumbnail) {
                throw '保存できるサムネイルがありません。'
            }

            $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
            $saveDialog.Title = 'サムネイルを保存'
            $saveDialog.Filter = 'PNG画像 (*.png)|*.png'
            $saveDialog.DefaultExt = 'png'
            $saveDialog.AddExtension = $true
            $safeTitle = ($songValue.Text -replace '[\\/:*?"<>|]', '_').Trim()
            if ([string]::IsNullOrWhiteSpace($safeTitle)) {
                $safeTitle = 'now-playing'
            }
            $saveDialog.FileName = "$safeTitle.png"

            if ($saveDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $state.Thumbnail.Save($saveDialog.FileName, [System.Drawing.Imaging.ImageFormat]::Png)
                $statusLabel.Text = "保存しました: $($saveDialog.FileName)"
            }
            $saveDialog.Dispose()
        }
        catch {
            $statusLabel.Text = $_.Exception.Message
            Write-AppLog -Level 'ERROR' -Message $_.Exception.ToString()
        }
    })

    $postText.Add_TextChanged($updateCharacterCount)
    $themeButton.Add_Click({
        $state.ThemeMode = switch ($state.ThemeMode) {
            'System' { 'Light' }
            'Light'  { 'Dark' }
            default  { 'System' }
        }
        Save-ThemeMode -ThemeMode $state.ThemeMode
        & $applyTheme
    })
    $refreshButton.Add_Click($loadMedia)
    $copyButton.Add_Click({
        try {
            & $copyText
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'なうぷれコピー',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $openXButton.Add_Click({
        try {
            & $copyText
            $encodedText = [System.Uri]::EscapeDataString($postText.Text)
            Start-Process "https://twitter.com/intent/tweet?text=$encodedText"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'なうぷれコピー',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $form.Add_Shown({
        & $applyTheme
        & $loadMedia
    })
    $form.Add_FormClosed({
        if ($null -ne $state.Thumbnail) {
            $thumbnailBox.Image = $null
            $state.Thumbnail.Dispose()
            $state.Thumbnail = $null
        }
    })

    & $applyTheme
    [void]$form.ShowDialog()
}

try {
    if ($HideConsole) {
        Hide-ConsoleWindow
    }

    Initialize-WindowsRuntime

    if ($SelfTest) {
        $media = Get-NowPlaying
        $formattedText = Format-PostText -Media $media
        if ([string]::IsNullOrWhiteSpace($formattedText)) {
            throw '投稿文が空です。'
        }

        Write-Output "OK: $formattedText"
        Write-Output "Source: $($media.SourceApp)"

        Add-Type -AssemblyName System.Drawing
        $thumbnail = Get-NowPlayingThumbnail
        if ($null -ne $thumbnail) {
            Write-Output "Thumbnail: $($thumbnail.Width)x$($thumbnail.Height)"
            $thumbnail.Dispose()
        }
        else {
            Write-Output 'Thumbnail: NotAvailable'
        }
        exit 0
    }

    Show-MainWindow
}
catch {
    Write-AppLog -Level 'FATAL' -Message $_.Exception.ToString()
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'なうぷれコピー',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error $_.Exception.Message
    }
    exit 1
}
