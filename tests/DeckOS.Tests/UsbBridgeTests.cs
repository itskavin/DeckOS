using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Lib;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    // Le PairingInfo.Port, que os testes de pareamento/mDNS trocam: nao rodar em paralelo com eles.
    [Collection("PairingPort")]
    public class UsbBridgeTests
    {
        [Fact]
        public void ParseDevices_SoOsProntos()
        {
            var output = "* daemon not running; starting now at tcp:5037\r\n" +
                         "* daemon started successfully\r\n" +
                         "List of devices attached\r\n" +
                         "9490bcb5\tdevice\r\n" +
                         "emulator-5554\toffline\r\n" +
                         "R58M123\tunauthorized\r\n" +
                         "192.168.0.5:5555\tdevice\r\n\r\n";
            Assert.Equal(new[] { "9490bcb5", "192.168.0.5:5555" }, UsbBridge.ParseDevices(output));
        }

        [Fact]
        public void HasReverse_ProcuraAPorta()
        {
            Assert.True(UsbBridge.HasReverse("UsbFfs tcp:4787 tcp:4787\n", 4787));
            Assert.False(UsbBridge.HasReverse("UsbFfs tcp:8081 tcp:8081\n", 4787));
            Assert.False(UsbBridge.HasReverse("", 4787));
        }

        [Fact]
        public void OwnerOfLoopbackClient_AchaOProcessoDoCliente()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            try
            {
                var serverPort = ((IPEndPoint)listener.LocalEndpoint).Port;
                using var client = new TcpClient();
                client.Connect(IPAddress.Loopback, serverPort);
                using var accepted = listener.AcceptTcpClient();
                var clientPort = ((IPEndPoint)client.Client.LocalEndPoint!).Port;

                Assert.Equal(Environment.ProcessId, UsbBridge.OwnerOfLoopbackClient(clientPort, serverPort));
            }
            finally
            {
                listener.Stop();
            }
        }

        [Fact]
        public void IsForwarded_ConexaoDeForaDoLoopbackNuncaE()
        {
            Assert.False(UsbBridge.IsForwarded(IPAddress.Parse("192.168.0.10"), 50000));
            Assert.False(UsbBridge.IsForwarded(null, 50000));
        }

        [Fact]
        public async Task Laco_SobreviveAUmAdbTravado()
        {
            // O primeiro "adb" sai logo, mas deixa um filho com a saida aberta (como o servidor
            // que o adb sobe quando nao ha um rodando). O filho so solta o pipe quando o teste
            // apaga o "hold": o celular so aparece se o prazo do comando funcionar de verdade.
            var dir = Path.Combine(Path.GetTempPath(), "deckos-usb-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var hold = Path.Combine(dir, "hold");
            File.WriteAllText(hold, "");
            string adb;
            if (OperatingSystem.IsWindows())
            {
                // Teto de ~60 s no filho: um teste abortado nao deixa processo vivo.
                File.WriteAllText(Path.Combine(dir, "hold.cmd"),
                    "@echo off\r\n" +
                    "set n=0\r\n" +
                    ":loop\r\n" +
                    "if not exist \"%~dp0hold\" exit /b 0\r\n" +
                    "set /a n+=1\r\n" +
                    "if %n% geq 60 exit /b 0\r\n" +
                    "ping -n 2 127.0.0.1 >nul\r\n" +
                    "goto loop\r\n");
                adb = Path.Combine(dir, "adb.cmd");
                File.WriteAllText(adb,
                    "@echo off\r\n" +
                    "echo %*>>\"%~dp0calls.txt\"\r\n" +
                    "if not exist \"%~dp0hung\" (\r\n" +
                    "  type nul > \"%~dp0hung\"\r\n" +
                    "  start \"\" /b cmd /d /c \"%~dp0hold.cmd\"\r\n" +
                    "  exit /b 0\r\n" +
                    ")\r\n" +
                    "if \"%1\"==\"devices\" (\r\n" +
                    "  echo List of devices attached\r\n" +
                    "  echo SER1\tdevice\r\n" +
                    ")\r\n");
            }
            else
            {
                adb = Path.Combine(dir, "adb");
                File.WriteAllText(adb,
                    "#!/bin/sh\n" +
                    "d=$(dirname \"$0\")\n" +
                    "echo \"$*\" >> \"$d/calls.txt\"\n" +
                    "if [ ! -f \"$d/hung\" ]; then touch \"$d/hung\"; " +
                    "( i=0; while [ -f \"$d/hold\" ] && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done ) & exit 0; fi\n" +
                    "if [ \"$1\" = devices ]; then printf 'List of devices attached\nSER1\tdevice\n'; fi\n");
                File.SetUnixFileMode(adb, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var bridge = new UsbBridge(NullLogger<UsbBridge>.Instance, () => adb,
                TimeSpan.FromMilliseconds(100), TimeSpan.FromSeconds(1));
            var connected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            bridge.Changed += () => { if (bridge.Devices.Count > 0) connected.TrySetResult(); };
            // Como o host: sem o SynchronizationContext do xUnit, que tem uma thread por nucleo
            // (2 no CI) dividida com os testes em paralelo. Com ele, cada volta do laco esperava
            // na fila dessas threads e o celular nao aparecia no prazo.
            await Task.Run(() => bridge.StartAsync(CancellationToken.None));
            try
            {
                // So o limite para falhar: o Changed acorda o teste assim que o celular entra.
                // O filho segura o pipe ate o finally, entao chegar aqui com o celular prova o prazo.
                await Task.WhenAny(connected.Task, Task.Delay(TimeSpan.FromSeconds(20)));

                Assert.Equal(new[] { "SER1" }, bridge.Devices);
                Assert.Contains($"-s SER1 reverse tcp:{PairingInfo.Port} tcp:{PairingInfo.Port}",
                    File.ReadAllText(Path.Combine(dir, "calls.txt")));
            }
            finally
            {
                try { File.Delete(hold); } catch { }
                await bridge.StopAsync(CancellationToken.None);
                // O filho sai em ate ~1 s depois que o "hold" some.
                for (var i = 0; i < 20 && Directory.Exists(dir); i++)
                {
                    try { Directory.Delete(dir, true); }
                    catch { await Task.Delay(100); }
                }
            }
        }
    }
}
