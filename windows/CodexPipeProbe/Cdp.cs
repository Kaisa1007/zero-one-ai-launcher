using System.IO;
using System.Text.Json;

namespace ZeroOne.CodexPipeProbe;

// The probe sends one request at a time. Notifications may be interleaved with replies.
internal sealed class Cdp(Stream input, Stream output) : IDisposable
{
    private const int MaxFrameBytes = 32 * 1024 * 1024;
    private readonly byte[] chunk = new byte[16384];
    private readonly MemoryStream frame = new();
    private int position, length, nextId;

    public async Task<JsonElement> SendAsync(
        string method, CancellationToken cancellation, object? parameters = null, string? sessionId = null)
    {
        int id = ++nextId;
        var request = new Dictionary<string, object> { ["id"] = id, ["method"] = method };
        if (parameters is not null)
            request.Add("params", parameters);
        if (sessionId is not null)
            request.Add("sessionId", sessionId);

        byte[] message = JsonSerializer.SerializeToUtf8Bytes(request);
        Array.Resize(ref message, message.Length + 1);
        await output.WriteAsync(message, cancellation);

        while (true)
        {
            if (position == length)
            {
                length = await input.ReadAsync(chunk, cancellation);
                position = 0;
                if (length == 0)
                    throw new EndOfStreamException($"{method}: CDP pipe closed before the reply");
            }

            int delimiter = Array.IndexOf(chunk, (byte)0, position, length - position);
            int end = delimiter < 0 ? length : delimiter;
            if (frame.Length + end - position > MaxFrameBytes)
                throw new InvalidDataException($"{method}: CDP reply exceeded {MaxFrameBytes} bytes");
            frame.Write(chunk, position, end - position);
            position = delimiter < 0 ? end : end + 1;
            if (delimiter < 0 || frame.Length == 0)
                continue;

            using var document = JsonDocument.Parse(frame.GetBuffer().AsMemory(0, (int)frame.Length));
            frame.SetLength(0);
            var reply = document.RootElement;
            if (!reply.TryGetProperty("id", out var replyId) || replyId.GetInt32() != id)
                continue;

            if (reply.TryGetProperty("error", out var error))
                throw new InvalidOperationException(
                    $"{method}: CDP {error.GetProperty("code")} ({error.GetProperty("message").GetString()})");
            return reply.GetProperty("result").Clone();
        }
    }

    public void Dispose() => frame.Dispose();
}
