using System;
using System.Runtime.InteropServices;

namespace CuaRdp.Native
{
    public static class KeyboardInteropTest
    {
        public static int Run()
        {
            int checks = 0;
            // Internal encoding keeps the up state in the sign bit; Invoke must strip it into the
            // VARIANT_BOOL array and put only scan|0x0100 into the LONG buffer the client reads.
            int[] sequence = { 0x015B, 0x0013, unchecked((int)0x80000013), unchecked((int)0x8000015B) };
            int[] expectedData = { 0x015B, 0x0013, 0x0013, 0x015B };
            short[] expectedUp = { 0, 0, -1, -1 };
            NativeKeyBatch.SendKeysCall inspect = delegate(IntPtr self, int count, IntPtr up, IntPtr data)
            {
                if (self != new IntPtr(42) || count != 4) throw new Exception("Incorrect SendKeys count/this pointer.");
                for (int i = 0; i < count; i++)
                {
                    if (Marshal.ReadInt32(data, i * 4) != expectedData[i]) throw new Exception("LONG array was corrupted.");
                    if (Marshal.ReadInt16(up, i * 2) != expectedUp[i]) throw new Exception("VARIANT_BOOL array was corrupted.");
                }
                checks++;
                return 0;
            };
            NativeKeyBatch.Invoke(new IntPtr(42), inspect, sequence);
            // The documented limit is 20 strokes per atomic call; reject before invoking COM.
            bool rejected = false;
            try { NativeKeyBatch.Invoke(new IntPtr(42), inspect, new int[21]); }
            catch (ArgumentException) { rejected = true; }
            if (!rejected) throw new Exception("Oversized SendKeys batch was accepted.");
            checks++;
            rejected = false;
            try { NativeKeyBatch.Invoke(new IntPtr(42), inspect, new int[0]); }
            catch (ArgumentException) { rejected = true; }
            if (!rejected) throw new Exception("Empty SendKeys batch was accepted.");
            checks++;
            try
            {
                NativeKeyBatch.Invoke(IntPtr.Zero, delegate { return unchecked((int)0x80004005); }, sequence);
                throw new Exception("SendKeys HRESULT was ignored.");
            }
            catch (COMException exception)
            {
                if (exception.ErrorCode != unchecked((int)0x80004005)) throw;
                checks++;
            }
            return checks;
        }
    }
}
