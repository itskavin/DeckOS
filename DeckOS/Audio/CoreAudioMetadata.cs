using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace DeckOS.Audio
{
    public readonly record struct AudioDeviceNames(string FriendlyName, string DeviceFriendlyName);

    /// <summary>
    /// Leitura direta de propriedades de endpoints Core Audio via <c>IPropertyStore.GetValue</c>.
    ///
    /// Por que existe: no NAudio 2.2.1, <see cref="MMDevice.FriendlyName"/> e
    /// <see cref="MMDevice.DeviceFriendlyName"/> fazem varredura linear em todas as propriedades
    /// do <c>PropertyStore</c> (<c>Contains</c> + indexador = até 2x N chamadas COM <c>GetAt(i)</c>
    /// por leitura). Em sistemas Windows 11 com ~196 propriedades por endpoint, cada acesso leva
    /// ~350–530 ms, transformando uma enumeração de 6 saídas em ~10–12 segundos.
    ///
    /// Chamando <c>IPropertyStore.GetValue(ref key)</c> diretamente pelos dois keys necessários
    /// (<c>PKEY_Device_FriendlyName</c> e <c>PKEY_DeviceInterface_FriendlyName</c>), a leitura de
    /// todos os endpoints ativos cai para ~1–6 ms mantendo dados 100% ao vivo e sem manter
    /// nenhum proxy COM residente entre chamadas.
    /// </summary>
    public static class CoreAudioMetadata
    {
        private const string FallbackName = "Unknown";
        private const int StgmRead = 0;
        private const uint ClsCtxInprocServer = 0x1;
        private static readonly Guid ClsidMMDeviceEnumerator = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
        private static readonly Guid IidIMMDeviceEnumerator = new("A95664D2-9614-4F35-A746-DE8DB63617E6");

        public static string ExtractTitle(string? friendlyName)
        {
            if (string.IsNullOrEmpty(friendlyName)) return string.Empty;
            var idx = friendlyName.IndexOf('(');
            return idx >= 0 ? friendlyName.Substring(0, idx).Trim() : friendlyName.Trim();
        }

        public static Dictionary<string, AudioDeviceNames> ReadActiveDeviceNames(DataFlow dataFlow, DeviceState deviceState)
        {
            var result = new Dictionary<string, AudioDeviceNames>(StringComparer.OrdinalIgnoreCase);
            var enumerator = CreateEnumerator();
            if (enumerator == null) return result;

            try
            {
                if (enumerator.EnumAudioEndpoints((int)dataFlow, (int)deviceState, out var collection) != 0 || collection == null)
                    return result;

                try
                {
                    if (collection.GetCount(out var count) != 0 || count <= 0)
                        return result;

                    for (var i = 0; i < count; i++)
                    {
                        if (collection.Item(i, out var device) != 0 || device == null) continue;
                        try
                        {
                            if (device.GetId(out var id) != 0 || string.IsNullOrEmpty(id)) continue;
                            var names = ReadNamesFromDevice(device);
                            if (names.HasValue)
                                result[id] = names.Value;
                        }
                        finally
                        {
                            ReleaseCom(device);
                        }
                    }
                }
                finally
                {
                    ReleaseCom(collection);
                }
            }
            catch
            {
                // Best-effort: callers fall back cleanly if Core Audio is unavailable.
            }
            finally
            {
                ReleaseCom(enumerator);
            }

            return result;
        }

        public static AudioDeviceNames? TryReadDeviceNames(string? deviceId)
        {
            if (string.IsNullOrWhiteSpace(deviceId)) return null;

            var enumerator = CreateEnumerator();
            if (enumerator == null) return null;

            try
            {
                if (enumerator.GetDevice(deviceId, out var device) != 0 || device == null)
                    return null;

                try
                {
                    return ReadNamesFromDevice(device);
                }
                finally
                {
                    ReleaseCom(device);
                }
            }
            catch
            {
                return null;
            }
            finally
            {
                ReleaseCom(enumerator);
            }
        }

        private static AudioDeviceNames? ReadNamesFromDevice(IMMDevice device)
        {
            if (device.OpenPropertyStore(StgmRead, out var store) != 0 || store == null)
                return null;

            try
            {
                var friendly = ReadStringProperty(store, PropertyKeys.PKEY_Device_FriendlyName) ?? FallbackName;
                var deviceFriendly = ReadStringProperty(store, PropertyKeys.PKEY_DeviceInterface_FriendlyName) ?? FallbackName;
                return new AudioDeviceNames(friendly, deviceFriendly);
            }
            finally
            {
                ReleaseCom(store);
            }
        }

        private static string? ReadStringProperty(IPropertyStore store, PropertyKey key)
        {
            var localKey = key;
            if (store.GetValue(ref localKey, out var propVariant) != 0)
                return null;

            try
            {
                return propVariant.Value as string;
            }
            catch
            {
                return null;
            }
            finally
            {
                PropVariantClear(ref propVariant);
            }
        }

        private static IMMDeviceEnumerator? CreateEnumerator()
        {
            var pUnk = IntPtr.Zero;
            try
            {
                var clsid = ClsidMMDeviceEnumerator;
                var iid = IidIMMDeviceEnumerator;
                var hr = CoCreateInstance(ref clsid, IntPtr.Zero, ClsCtxInprocServer, ref iid, out pUnk);
                if (hr != 0 || pUnk == IntPtr.Zero) return null;

                // GetUniqueObjectForIUnknown cria um RCW isolado (fora do cache global do CLR).
                // Sem isso, no MTA o MMDeviceEnumerator compartilha o mesmo IUnknown* singleton e
                // um System.__ComObject aqui faria new NAudio.MMDeviceEnumerator() concorrente
                // lançar InvalidCastException ao tentar obter MMDeviceEnumeratorComObject.
                return Marshal.GetUniqueObjectForIUnknown(pUnk) as IMMDeviceEnumerator;
            }
            catch
            {
                return null;
            }
            finally
            {
                if (pUnk != IntPtr.Zero)
                    Marshal.Release(pUnk);
            }
        }

        private static void ReleaseCom(object? comObject)
        {
            if (comObject == null) return;
            try
            {
                if (Marshal.IsComObject(comObject))
                    Marshal.ReleaseComObject(comObject);
            }
            catch
            {
                // Ignore teardown errors on invalidated devices.
            }
        }

        [DllImport("ole32.dll")]
        private static extern int CoCreateInstance(
            ref Guid rclsid,
            IntPtr pUnkOuter,
            uint dwClsContext,
            ref Guid riid,
            out IntPtr ppv);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pvar);

        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig]
            int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);

            [PreserveSig]
            int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);

            [PreserveSig]
            int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        }

        [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig]
            int GetCount(out int numDevices);

            [PreserveSig]
            int Item(int deviceNumber, out IMMDevice device);
        }

        [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig]
            int Activate(
                ref Guid iid,
                int clsCtx,
                IntPtr activationParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);

            [PreserveSig]
            int OpenPropertyStore(int stgmAccess, out IPropertyStore properties);

            [PreserveSig]
            int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

            [PreserveSig]
            int GetState(out int state);
        }

        [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig]
            int GetCount(out int propCount);

            [PreserveSig]
            int GetAt(int property, out PropertyKey key);

            [PreserveSig]
            int GetValue(ref PropertyKey key, out PropVariant value);

            [PreserveSig]
            int SetValue(ref PropertyKey key, ref PropVariant value);

            [PreserveSig]
            int Commit();
        }
    }
}
