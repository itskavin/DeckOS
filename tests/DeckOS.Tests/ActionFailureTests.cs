using System;
using System.Net;
using System.Net.Http.Json;
using System.Threading.Tasks;
using DeckOS.Actions;
using DeckOS.Auth;
using DeckOS.Models;
using DeckOS.Services;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace DeckOS.Tests;

public class ActionFailureTests
{
    [Fact]
    public async Task MediaCommandRejectionIsAnExecutionFailure()
    {
        var media = new Mock<DeckOS.Platform.IMediaControlService>();
        media.Setup(m => m.SendCommandAsync(null, "playpause"))
            .ReturnsAsync(new MediaCommandResult { Success = false });
        var provider = new DeckOS.Actions.Providers.MediaProvider(media.Object,
            Mock.Of<Microsoft.AspNetCore.SignalR.IHubContext<DeckOS.Hubs.DeckHub>>(),
            NullLogger<DeckOS.Actions.Providers.MediaProvider>.Instance);
        var executor = new ActionExecutorService(NullLogger<ActionExecutorService>.Instance, new[] { provider });
        var failure = await Assert.ThrowsAsync<ActionExecutionException>(() => executor.ExecuteActionAsync(
            new DeckAction { Type = "media", Parameters = new() { ["command"] = "playpause" } }));
        Assert.Equal("action_not_applied", failure.Code);
    }

    private sealed class FailingProvider : IActionProvider
    {
        public string Type => "test_failure";
        public ActionSchema Describe() => new() { Type = Type, Title = Type };
        public Task ExecuteAsync(ActionContext context) => throw new InvalidOperationException("secret-provider-details");
    }

    [Fact]
    public async Task FailedExecuteAndSavedPressReturnFailureWithoutProviderDetails()
    {
        using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(b =>
            b.ConfigureTestServices(s => s.AddSingleton<IActionProvider, FailingProvider>()));
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-API-KEY", ApiKeyProvider.GetKey());
        var action = new DeckAction { Type = "test_failure" };
        var profile = new DeckProfile { Id = "failure_" + Guid.NewGuid().ToString("N") };
        profile.Buttons.Add(new DeckButton { Id = "fail", Action = action });
        factory.Services.GetRequiredService<StreamDeckConfigService>().SaveProfile(profile);
        try
        {
            using var execute = await client.PostAsJsonAsync("/api/StreamDeck/execute", action);
            using var press = await client.PostAsJsonAsync("/api/StreamDeck/press", new { profileId = profile.Id, buttonId = "fail" });
            foreach (var response in new[] { execute, press })
            {
                Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
                var body = await response.Content.ReadAsStringAsync();
                Assert.Contains("action_failed", body);
                Assert.DoesNotContain("secret-provider-details", body);
            }
            using var unknown = await client.PostAsJsonAsync("/api/StreamDeck/execute", new DeckAction { Type = "unknown-test-action" });
            Assert.Equal(HttpStatusCode.BadRequest, unknown.StatusCode);
        }
        finally { factory.Services.GetRequiredService<StreamDeckConfigService>().DeleteProfile(profile.Id); }
    }
}
