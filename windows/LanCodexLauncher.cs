using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("LAN Codex")]
[assembly: AssemblyDescription("LAN-only Codex desktop bridge")]
[assembly: AssemblyCompany("\u7FCE\u7FBD")]
[assembly: AssemblyProduct("LAN Codex")]
[assembly: AssemblyCopyright("Copyright (c) 2026 \u7FCE\u7FBD")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        var appRoot = AppDomain.CurrentDomain.BaseDirectory;
        var scriptPath = Path.Combine(appRoot, "scripts", "windows-wpf-control-panel.ps1");
        if (!File.Exists(scriptPath))
        {
            MessageBox.Show("The LAN Codex control panel is missing.", "LAN Codex", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var powershellPath = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath),
                WorkingDirectory = appRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "LAN Codex", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
