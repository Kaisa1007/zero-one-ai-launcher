using System.IO;
using System.Text.Json;

namespace ZeroOne.CodexPipeProbe;

internal static class SkinScript
{
    public const string PageState = """
        ({
          ready: Boolean(document.querySelector('main') &&
            document.querySelector('[data-composer-markdown], main [contenteditable="true"], .ProseMirror, textarea')),
          skin: Boolean(window.__zoSkin && document.getElementById('zo-skin')),
          dark: matchMedia('(prefers-color-scheme: dark)').matches
        })
        """;

    public static string Build(string skinDirectory, string imagesDirectory)
    {
        string css = File.ReadAllText(Path.Combine(skinDirectory, "codex_skin.css"));
        string logo = Convert.ToBase64String(File.ReadAllBytes(Path.Combine(imagesDirectory, "hiden_logo_vec@3x.png")));
        css = css.Replace("{{ACCENT}}", "#D6FA0D", StringComparison.Ordinal)
                 .Replace("{{ACCENT_NOHASH}}", "D6FA0D", StringComparison.Ordinal)
                 .Replace("{{ACCENT_RGB}}", "214, 250, 13", StringComparison.Ordinal)
                 .Replace("{{LOGO_URL}}", "data:image/png;base64," + logo, StringComparison.Ordinal);
        string js = File.ReadAllText(Path.Combine(skinDirectory, "codex_skin.js"))
            .Replace("{{CSS_JSON}}", JsonSerializer.Serialize(css), StringComparison.Ordinal);
        return $"(() => {{ if (location.protocol !== 'app:') return 'outside-app'; return ({js}\n); }})()";
    }
}
