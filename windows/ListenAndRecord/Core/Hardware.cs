using System.Runtime.InteropServices;
using System.Runtime.Intrinsics.X86;
using Microsoft.Win32;

namespace ListenAndRecord.Core;

/// <summary>Detects the PC's capabilities to recommend a model and settings.</summary>
public static class Hardware
{
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);

    public static double TotalRamGb
    {
        get
        {
            var m = new MemoryStatusEx { dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>() };
            return GlobalMemoryStatusEx(ref m) ? m.ullTotalPhys / 1073741824.0 : 4;
        }
    }

    public static bool HasAvx2 => Avx2.IsSupported && Fma.IsSupported;

    public static int LogicalCores => Environment.ProcessorCount;

    public static string CpuName =>
        (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", "")
            ?.ToString() ?? "").Trim();

    /// <summary>Old CPU without AVX2 or little memory (e.g. Core i5-760 with 4 GB).</summary>
    public static bool IsWeak => !HasAvx2 || TotalRamGb < 6;

    public static int Threads => Math.Clamp(LogicalCores >= 8 ? LogicalCores - 2 : LogicalCores, 2, 8);

    public static string RecommendedModelId => IsWeak ? "small" : "large-v3-turbo-q5_0";

    public static bool RecommendedHighAccuracy => !IsWeak;

    public static string Summary =>
        $"{CpuName}  ·  ОЗУ {TotalRamGb:0.#} ГБ  ·  потоков: {LogicalCores}  ·  AVX2: {(HasAvx2 ? "есть" : "нет")}";
}
