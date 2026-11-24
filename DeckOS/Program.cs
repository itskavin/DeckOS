using System.Reflection;
using System.Diagnostics;
using System.IO;
using DeckOS.Lib;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.Json;
using NLog.Extensions.Logging;
using Microsoft.OpenApi.Models;

namespace DeckOS
{
    public class Program
    {
#if WINDOWS
        public static frmPrincipal? FrmPrincipal { get; private set; }

        public static readonly AppUpdater Updater = new();
#endif

        /// <summary>Primeira execucao depois de instalar pelo DeckOS-Setup.exe.</summary>
        public static bool FirstRunAfterInstall { get; private set; }

        [STAThread]
        public static void Main(string[] args)
        {
#if WINDOWS
            // Precisa ser a primeira coisa: o instalador/atualizador do Velopack chama o
            // proprio exe com argumentos de hook e espera que ele saia logo. Fora de uma
            // copia instalada (zip, dotnet run) nao faz nada.
            Velopack.VelopackApp.Build()
                .OnFirstRun(_ => FirstRunAfterInstall = true)
                .OnBeforeUninstallFastCallback(_ => frmPrincipal.RemoveAutoStartIfOurs())
                .Run();
#endif

            Lib.Log.DropOversizedLegacyLog();

            // Remote devices use TLS; HTTP is only for the same-PC configurator.
            // Explicit URL/Kestrel settings are preserved and checked below.
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")) && !HasConfiguredUrls(args))
            {
                Environment.SetEnvironmentVariable("ASPNETCORE_URLS", $"http://127.0.0.1:4787;https://0.0.0.0:{Lib.PairingInfo.DefaultPort}");
            }

            // Modo headless: sem janela/bandeja, roda apenas o servidor web.
            // Útil para autostart silencioso, execução sem desktop ou depuração.
            // Ctrl+C encerra graciosamente via ConsoleLifetime do host.
            // Diagnóstico/headless de pareamento: imprime a URI e salva o QR em PNG, depois sai.
            if (args.Contains("--print-pairing"))
            {
                var uri = Lib.PairingInfo.BuildUri();
                Console.WriteLine(uri);
                var pngPath = Path.Combine(Path.GetTempPath(), "deckos-pair.png");
                File.WriteAllBytes(pngPath, Lib.PairingInfo.BuildQrPng(uri));
                Console.WriteLine("QR_PNG=" + pngPath);
                return;
            }

            // Uma instancia so. A segunda nao consegue a porta 4787 mas ficava viva na bandeja,
            // e se pegasse a vez no boot disputaria o pipe do Discord e o push da Tuya com a
            // primeira. DECKOS_DATA_DIR separa as instancias de teste.
            using var instance = new Mutex(true, InstanceMutexName(), out var firstInstance);
            if (!firstInstance)
            {
                if (!OperatingSystem.IsWindows()) Console.Error.WriteLine("DeckOS já está rodando.");
                return;
            }

#if WINDOWS
            if (args.Contains("--headless") || args.Contains("--no-tray"))
            {
                RunWebAppAsync(args, CancellationToken.None).GetAwaiter().GetResult();
                return;
            }

            // Cancellation token to coordinate shutdown between WinForms and the web server
            var cts = new CancellationTokenSource();

            // Inicializa e roda o servidor web em paralelo, observando o token
            var webTask = RunWebAppAsync(args, cts.Token);

            // App de bandeja: a janela fica invisível e toda a interação é pelo ícone na bandeja.
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            FrmPrincipal = new frmPrincipal();

            Application.Run(FrmPrincipal);

            // Tecla presa pelo deck (seta segurada, Shift travado) nao fica apertada no Windows.
            DeckOS.Lib.Input.HeldKeys.Shared.ReleaseAll();

            // Solicita encerramento gracioso do servidor web e discovery
            try
            {
                cts.Cancel();
            }
            catch { }

            // Garante que o servidor finalize junto
            webTask.Wait();
#else
            RunConsole(args);
#endif
        }

        /// <summary>
        /// Nome do mutex de instancia unica. No Windows, o de sempre; no macOS/Linux o nome vira
        /// arquivo em /tmp/.dotnet/shm e nao pode ter "/" (o caminho do DECKOS_DATA_DIR tem).
        /// </summary>
        private static string InstanceMutexName()
        {
            var dataDir = Environment.GetEnvironmentVariable("DECKOS_DATA_DIR") ?? "default";
            if (OperatingSystem.IsWindows())
                return @"Local\DeckOS.Instance." + dataDir.Replace('\\', '/');
            var hash = Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(dataDir)), 0, 6);
            return "DeckOS.Instance." + hash;
        }

        /// <summary>
        /// macOS e Linux: sem bandeja. O servidor roda como um processo de console (ou servico
        /// do launchd/systemd, ver scripts/) e o pareamento sai no terminal: endereco do
        /// configurador e o QR em texto. --open abre o configurador no navegador.
        /// </summary>
        private static void RunConsole(string[] args)
        {
            // QR em meio-blocos e acentos: o terminal precisa receber UTF-8.
            try { Console.OutputEncoding = System.Text.Encoding.UTF8; } catch { }
            var host = CreateHostBuilder(args).Build();
            host.Start();
            try
            {
                Lib.ConsoleBanner.Print(Console.Out);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Pareamento] {ex.Message}");
            }
            if (args.Contains("--open")) Lib.ConsoleBanner.OpenBrowser(Lib.ConsoleBanner.WebUrl);
            host.WaitForShutdown();
            // Tecla presa pelo deck (seta segurada, Shift travado) nao fica apertada.
            DeckOS.Lib.Input.HeldKeys.Shared.ReleaseAll();
        }

        /// <summary>
        /// True se a origem (header Origin de uma requisição de navegador) é o próprio PC
        /// (loopback) ou um IP de LAN privada — de onde o configurador web legítimo roda.
        /// Hostnames públicos (ex.: evil.com) retornam false, barrando CORS de sites externos.
        /// </summary>
        private static bool IsLocalOrLanOrigin(string origin)
        {
            if (string.IsNullOrEmpty(origin)) return false;
            if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri)) return false;
            if (uri.IsLoopback) return true;
            if (!System.Net.IPAddress.TryParse(uri.Host, out var ip)) return false; // hostname público → barra
            var b = ip.GetAddressBytes();
            if (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && b.Length == 4)
            {
                return b[0] == 10                                   // 10.0.0.0/8
                    || (b[0] == 172 && b[1] >= 16 && b[1] <= 31)    // 172.16.0.0/12
                    || (b[0] == 192 && b[1] == 168)                 // 192.168.0.0/16
                    || (b[0] == 169 && b[1] == 254)                 // 169.254.0.0/16 (link-local)
                    || b[0] == 127;                                 // 127.0.0.0/8
            }
            if (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6)
                return ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal
                    || (b.Length == 16 && (b[0] & 0xFE) == 0xFC);   // fc00::/7 (ULA)
            return false;
        }

        /// <summary>Verifica se o usuario passou --urls ou configurou urls/Kestrel:Endpoints no appsettings.json.</summary>
        private static bool HasConfiguredUrls(string[] args)
        {
            if (args.Any(a => a.Equals("--urls", StringComparison.OrdinalIgnoreCase)
                           || a.StartsWith("--urls=", StringComparison.OrdinalIgnoreCase)))
                return true;
            try
            {
                var cfg = new ConfigurationBuilder()
                    .SetBasePath(ResolveContentRoot())
                    .AddJsonFile("appsettings.json", optional: true)
                    .Build();
                return !string.IsNullOrWhiteSpace(cfg["urls"])
                    || cfg.GetSection("Kestrel:Endpoints").GetChildren().Any();
            }
            catch
            {
                return false;
            }
        }

        private static string ResolveContentRoot()
        {
            var cwd = Directory.GetCurrentDirectory();
            return File.Exists(Path.Combine(cwd, "wwwroot", "index.html"))
                ? cwd
                : AppContext.BaseDirectory;
        }

        public static IHostBuilder CreateHostBuilder(string[] args)
        {
            // Em dev (dotnet run a partir de DeckOS/) o wwwroot fonte está no diretório
            // atual; no .exe publicado, ao lado do executável. Preferir o diretório atual
            // evita servir uma cópia velha de bin/ (que o build cria ao copiar o wwwroot).
            var contentRoot = ResolveContentRoot();
            return Host.CreateDefaultBuilder(args)
                .UseContentRoot(contentRoot)
                .ConfigureLogging(logging =>
                {
                    logging.ClearProviders();
                    logging.AddFilter("Microsoft.AspNetCore.Hosting.Diagnostics", LogLevel.Warning);
                    logging.AddConsole();
                    try
                    {
                        logging.AddNLog();
                    }
                    catch { }
                })
                .ConfigureWebHostDefaults(webBuilder =>
                {
                    webBuilder.ConfigureKestrel((context, options) => {
                        var configuredUrls = context.Configuration["urls"];
                        var endpointUrls = context.Configuration.GetSection("Kestrel:Endpoints").GetChildren().Select(e => e["Url"]);
                        foreach (var url in (configuredUrls ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Concat(endpointUrls.Where(u => u != null)!))
                        {
                            if (url != null && url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                                (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || !uri.IsLoopback))
                                throw new InvalidOperationException("DeckOS HTTP must bind to loopback only. Use HTTPS for LAN connections (default secure port 4788), and http://127.0.0.1:4787 for the PC configurator.");
                        }
                        options.ConfigureHttpsDefaults(https => https.ServerCertificate = DeckOS.Auth.CompanionCertificate.Get());
                    });
                    webBuilder.ConfigureServices((context, services) =>
                    {
                        // Atualiza PairingInfo.Port assim que o Kestrel escutar a porta real,
                        // antes de o mDNS anunciar ou do banner imprimir o QR.
                        services.AddHostedService<DeckOS.Lib.BoundPortWatcher>();

                        // Variáveis de app/versão
                        services.AddControllers()
                                .AddJsonOptions(options =>
                                {
                                    options.JsonSerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
                                    options.JsonSerializerOptions.PropertyNameCaseInsensitive = true;
                                });

                        // Authentication: API Key
                        services.AddAuthentication("ApiKey")
                                .AddScheme<Microsoft.AspNetCore.Authentication.AuthenticationSchemeOptions, DeckOS.Auth.ApiKeyAuthenticationHandler>("ApiKey", null);
                        services.AddAuthorization(options =>
                        {
                            // Exige a API key em TODOS os endpoints, exceto os marcados [AllowAnonymous].
                            options.FallbackPolicy = new Microsoft.AspNetCore.Authorization.AuthorizationPolicyBuilder()
                                .RequireAuthenticatedUser()
                                .Build();
                        });

                        // Cliente HTTP p/ integrações externas (ex.: busca de sons no MyInstants).
                        services.AddHttpClient();

                        // Registro condicional do discovery (configuracao compartilhada com /api/platform).
                        var discovery = DeckOS.Platform.DiscoveryAvailability.FromConfiguration(context.Configuration);
                        services.AddSingleton(discovery);
                        if (discovery.Udp)
                        {
                            services.AddHostedService<DeckOS.Lib.DiscoveryServer>();
                            // Bonjour para o iPhone, que nao faz broadcast UDP.
                            if (discovery.Mdns) services.AddHostedService<DeckOS.Lib.MdnsAdvertiser>();
                            Console.WriteLine("[Discovery] Serviço registrado.");
                        }
                        else
                        {
                            Console.WriteLine("[Discovery] Serviço desativado (config).");
                        }

                        services.AddSwaggerGen(c =>
                        {
                            string appName = Assembly.GetExecutingAssembly().GetName().Name!;
                            string version = "v" + Assembly.GetExecutingAssembly().GetName().Version!.ToString().Replace(".", "").Replace("0", "");
                            c.SwaggerDoc("v1", new OpenApiInfo { Title = appName, Version = version });
                        });
                        services.AddCors(options =>
                        {
                            options.AddPolicy(name: "_myAllowSpecificOrigins", policy =>
                            {
                                // SEGURANÇA: não refletir qualquer origem. Só o próprio host
                                // (loopback) e IPs de LAN privada — que é de onde o configurador
                                // web legítimo roda. Sites públicos (evil.com) são barrados, o que
                                // impede um site que a vítima visite de ler respostas da API.
                                // Sem AllowCredentials: a auth é por header X-API-KEY, não cookie.
                                policy.SetIsOriginAllowed(IsLocalOrLanOrigin)
                                      .AllowAnyHeader()
                                      .AllowAnyMethod();
                            });
                        });

                        // Servicos do DeckOS, por area (ver ServiceRegistration.cs). O que muda por
                        // sistema (teclado, audio, midia, energia...) fica no AddPlatform.
                        services.AddPlatform()
                                .AddDeckCore()
                                .AddActionProviders()
                                .AddIntegrations();

                        services.AddSignalR();
                    });

                    webBuilder.Configure(app =>
                    {
                        var env = app.ApplicationServices.GetRequiredService<IHostEnvironment>();
                        string appName = Assembly.GetExecutingAssembly().GetName().Name!;
                        string version = "v" + Assembly.GetExecutingAssembly().GetName().Version!.ToString().Replace(".", "").Replace("0", "");

                        if (env.IsDevelopment())
                        {
                            app.UseDeveloperExceptionPage();
                            app.UseSwagger();
                            app.UseSwaggerUI(c => c.SwaggerEndpoint("/swagger/v1/swagger.json", $"{appName} {version}"));
                        }

                        app.Use(async (ctx, next) =>
                        {
                            if (!DeckOS.Auth.TransportBoundary.Allowed(ctx)) { ctx.Response.StatusCode = 403; return; }
                            await next();
                        });

                        // Idioma da resposta (Accept-Language) para L.T.
                        app.UseLanguage();

                        // Enable static files for Web Editor
                        app.UseWebBuildStamp(app.ApplicationServices.GetRequiredService<IWebHostEnvironment>());
                        app.UseDefaultFiles();
                        // Sem Cache-Control o navegador guarda por um tempo que ele mesmo
                        // estima, e depois de uma atualizacao misturava o JS novo com a fonte
                        // de icones antiga (enxuta pelo build): icone novo saia em branco.
                        // no-cache revalida pelo ETag: em localhost custa um 304.
                        app.UseStaticFiles(new StaticFileOptions
                        {
                            OnPrepareResponse = ctx =>
                                ctx.Context.Response.Headers.CacheControl = "no-cache",
                        });

                        app.UseRouting();
                        app.UseCors("_myAllowSpecificOrigins"); // CORS em qualquer ambiente (web client)
                        app.UseAuthentication();
                        app.UseAuthorization();
                        app.UseEndpoints(endpoints =>
                        {
                            // Endpoint anônimo para o app checar conectividade (antes de ter a chave).
                            endpoints.MapGet("/api/ping", () =>
                                Microsoft.AspNetCore.Http.Results.Ok(new { ok = true, name = Environment.MachineName }))
                                .AllowAnonymous();

                            // Entrega a API key APENAS para quem acessa via loopback (o próprio PC).
                            // Deixa o configurador web (servido pelo PC) autenticar sem QR.
                            endpoints.MapGet("/api/pairing/local-key", (Microsoft.AspNetCore.Http.HttpContext ctx) =>
                            {
                                // Loopback que vem do adb e um celular pelo USB: qualquer app dele
                                // alcanca o 127.0.0.1:4787 enquanto o encaminhamento existe.
                                if (!DeckOS.Auth.TransportBoundary.IsLocalAdmin(ctx))
                                    return Microsoft.AspNetCore.Http.Results.StatusCode(403);

                                // SEGURANÇA: bloqueia leitura por site cross-site (o navegador da
                                // vítima faz fetch a partir de 127.0.0.1, mas o browser marca a
                                // requisição). Sec-Fetch-Site é um header proibido — JS não forja.
                                // Fetch de outro site vem "cross-site"; o configurador servido aqui
                                // vem "same-origin"/"none". Sem esse gate, qualquer site leria a chave.
                                var secFetchSite = ctx.Request.Headers["Sec-Fetch-Site"].ToString();
                                if (!string.IsNullOrEmpty(secFetchSite) &&
                                    secFetchSite != "same-origin" && secFetchSite != "none")
                                    return Microsoft.AspNetCore.Http.Results.StatusCode(403);
                                var origin = ctx.Request.Headers["Origin"].ToString();
                                if (!string.IsNullOrEmpty(origin) && !IsLocalOrLanOrigin(origin))
                                    return Microsoft.AspNetCore.Http.Results.StatusCode(403);

                                return Microsoft.AspNetCore.Http.Results.Ok(new { key = DeckOS.Auth.ApiKeyProvider.GetKey() });
                            }).AllowAnonymous();

                            endpoints.MapControllers();
                            endpoints.MapHub<DeckOS.Hubs.DeckHub>("/deckHub");
                        });
                    });
                });
        }

        private static async Task RunWebAppAsync(string[] args, CancellationToken token)
        {
            var host = CreateHostBuilder(args).Build();
            await host.RunAsync(token);
        }
    }
}
