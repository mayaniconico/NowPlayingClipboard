using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.Media.Control;
using Windows.Storage.Streams;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            return RunAsync(args).GetAwaiter().GetResult();
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static async Task<int> RunAsync(string[] args)
    {
        if (args.Length != 1 || string.IsNullOrWhiteSpace(args[0]))
        {
            Console.Error.WriteLine("Usage: ThumbnailFetcher <output-path>");
            return 1;
        }

        GlobalSystemMediaTransportControlsSessionManager manager =
            await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();

        GlobalSystemMediaTransportControlsSession[] sessions = manager.GetSessions().ToArray();
        if (sessions.Length == 0)
        {
            return 2;
        }

        GlobalSystemMediaTransportControlsSession currentSession = manager.GetCurrentSession();
        GlobalSystemMediaTransportControlsSession selectedSession = null;

        if (currentSession != null &&
            currentSession.GetPlaybackInfo().PlaybackStatus ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
        {
            selectedSession = currentSession;
        }
        else
        {
            selectedSession = sessions.FirstOrDefault(session =>
                session.GetPlaybackInfo().PlaybackStatus ==
                    GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing);
        }

        if (selectedSession == null)
        {
            selectedSession = currentSession ?? sessions[0];
        }

        GlobalSystemMediaTransportControlsSessionMediaProperties properties =
            await selectedSession.TryGetMediaPropertiesAsync();

        if (properties?.Thumbnail == null)
        {
            return 2;
        }

        byte[] imageBytes;
        using (IRandomAccessStreamWithContentType randomStream =
            await properties.Thumbnail.OpenReadAsync())
        using (Stream inputStream = randomStream.AsStreamForRead())
        using (var memoryStream = new MemoryStream())
        {
            await inputStream.CopyToAsync(memoryStream);
            imageBytes = memoryStream.ToArray();
        }

        if (imageBytes.Length == 0)
        {
            return 2;
        }

        string outputPath = Path.GetFullPath(args[0]);
        File.WriteAllBytes(outputPath, imageBytes);
        return 0;
    }
}
