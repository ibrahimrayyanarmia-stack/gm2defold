# Decode any Media-Foundation-readable audio file (mp3, m4a, ...) to 16-bit PCM WAV.
# usage: powershell -File mp3towav.ps1 <in> <out.wav>
param([string]$inp, [string]$outp)
Add-Type -TypeDefinition @"
using System; using System.IO; using System.Runtime.InteropServices;
[ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFSourceReader {
  void GetStreamSelection(int s, out bool sel); void SetStreamSelection(int s, bool sel);
  void GetNativeMediaType(int s, int i, out IntPtr t); void GetCurrentMediaType(int s, out IMFMediaType t);
  void SetCurrentMediaType(int s, IntPtr reserved, IMFMediaType t); void SetCurrentPosition(ref Guid g, IntPtr v);
  void ReadSample(int s, int flags, out int actual, out int sflags, out long ts, out IMFSample sample);
}
[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFMediaType {
  void GetItem(ref Guid k, IntPtr v); void GetItemType(ref Guid k, out int t); void CompareItem(ref Guid k, IntPtr v, out bool r);
  void Compare(IntPtr a, int t, out bool r); void GetUINT32(ref Guid k, out int v); void GetUINT64(ref Guid k, out long v);
  void GetDouble(ref Guid k, out double v); void GetGUID(ref Guid k, out Guid v); void GetStringLength(ref Guid k, out int l);
  void GetString(ref Guid k, IntPtr s, int n, out int l); void GetAllocatedString(ref Guid k, out IntPtr s, out int l);
  void GetBlobSize(ref Guid k, out int s); void GetBlob(ref Guid k, IntPtr b, int n, out int s); void GetAllocatedBlob(ref Guid k, out IntPtr b, out int s);
  void GetUnknown(ref Guid k, ref Guid r, out IntPtr o); void SetItem(ref Guid k, IntPtr v); void DeleteItem(ref Guid k); void DeleteAllItems();
  void SetUINT32(ref Guid k, int v); void SetUINT64(ref Guid k, long v); void SetDouble(ref Guid k, double v); void SetGUID(ref Guid k, ref Guid v);
}
[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFSample {
  void GetItem(IntPtr k, IntPtr v); void GetItemType(IntPtr k, out int t); void CompareItem(IntPtr k, IntPtr v, out bool r);
  void Compare(IntPtr a, int t, out bool r); void GetUINT32(IntPtr k, out int v); void GetUINT64(IntPtr k, out long v);
  void GetDouble(IntPtr k, out double v); void GetGUID(IntPtr k, out Guid v); void GetStringLength(IntPtr k, out int l);
  void GetString(IntPtr k, IntPtr s, int n, out int l); void GetAllocatedString(IntPtr k, out IntPtr s, out int l);
  void GetBlobSize(IntPtr k, out int s); void GetBlob(IntPtr k, IntPtr b, int n, out int s); void GetAllocatedBlob(IntPtr k, out IntPtr b, out int s);
  void GetUnknown(IntPtr k, IntPtr r, out IntPtr o); void SetItem(IntPtr k, IntPtr v); void DeleteItem(IntPtr k); void DeleteAllItems();
  void SetUINT32(IntPtr k, int v); void SetUINT64(IntPtr k, long v); void SetDouble(IntPtr k, double v); void SetGUID(IntPtr k, IntPtr v);
  void SetString(IntPtr k, IntPtr v); void SetBlob(IntPtr k, IntPtr b, int n); void SetUnknown(IntPtr k, IntPtr u);
  void LockStore(); void UnlockStore(); void GetCount(out int c); void GetItemByIndex(int i, IntPtr k, IntPtr v); void CopyAllItems(IntPtr d);
  void GetSampleFlags(out int f); void SetSampleFlags(int f); void GetSampleTime(out long t); void SetSampleTime(long t);
  void GetSampleDuration(out long d); void SetSampleDuration(long d); void GetBufferCount(out int c); void GetBufferByIndex(int i, out IntPtr b);
  void ConvertToContiguousBuffer(out IMFMediaBuffer b);
}
[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFMediaBuffer { void Lock(out IntPtr p, out int max, out int cur); void Unlock(); void GetCurrentLength(out int l); void SetCurrentLength(int l); void GetMaxLength(out int l); }
public static class Dec {
  [DllImport("mfplat.dll")] static extern int MFStartup(int v, int f);
  [DllImport("mfreadwrite.dll")] static extern int MFCreateSourceReaderFromURL([MarshalAs(UnmanagedType.LPWStr)] string u, IntPtr a, out IMFSourceReader r);
  [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IMFMediaType t);
  public static void Run(string inp, string outp) {
    Marshal.ThrowExceptionForHR(MFStartup(0x20070, 0));
    IMFSourceReader r; Marshal.ThrowExceptionForHR(MFCreateSourceReaderFromURL(inp, IntPtr.Zero, out r));
    const int AUDIO = unchecked((int)0xFFFFFFFD);
    IMFMediaType t; MFCreateMediaType(out t);
    Guid major = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f"), audio = new Guid("73647561-0000-0010-8000-00AA00389B71");
    Guid sub = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), pcm = new Guid("00000001-0000-0010-8000-00AA00389B71");
    t.SetGUID(ref major, ref audio); t.SetGUID(ref sub, ref pcm);
    Guid bps = new Guid("f2deb57f-40fa-4764-aa33-ed4f2d1ff669"); t.SetUINT32(ref bps, 16);
    r.SetStreamSelection(-2, false); r.SetStreamSelection(AUDIO, true);
    r.SetCurrentMediaType(AUDIO, IntPtr.Zero, t);
    IMFMediaType ot; r.GetCurrentMediaType(AUDIO, out ot);
    Guid gch = new Guid("37e48bf5-645e-4c5b-89de-ada9e29b696a"), gsr = new Guid("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    int ch, sr; ot.GetUINT32(ref gch, out ch); ot.GetUINT32(ref gsr, out sr);
    var ms = new MemoryStream();
    while (true) {
      int a, f; long ts; IMFSample s; r.ReadSample(AUDIO, 0, out a, out f, out ts, out s);
      if ((f & 2) != 0) break;
      if (s == null) continue;
      IMFMediaBuffer b; s.ConvertToContiguousBuffer(out b);
      IntPtr p; int mx, cur; b.Lock(out p, out mx, out cur);
      byte[] d = new byte[cur]; Marshal.Copy(p, d, 0, cur); ms.Write(d, 0, cur); b.Unlock();
      Marshal.ReleaseComObject(b); Marshal.ReleaseComObject(s);
    }
    byte[] data = ms.ToArray();
    using (var w = new BinaryWriter(File.Create(outp))) {
      w.Write(new char[]{'R','I','F','F'}); w.Write(36 + data.Length); w.Write(new char[]{'W','A','V','E','f','m','t',' '});
      w.Write(16); w.Write((short)1); w.Write((short)ch); w.Write(sr); w.Write(sr * ch * 2); w.Write((short)(ch * 2)); w.Write((short)16);
      w.Write(new char[]{'d','a','t','a'}); w.Write(data.Length); w.Write(data);
    }
    Console.WriteLine("ok " + ch + "ch " + sr + "Hz " + data.Length + " bytes");
  }
}
"@
[Dec]::Run($inp, $outp)
