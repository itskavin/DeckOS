using DeckOS.Services;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>
    /// Estado devolvido depois de um comando de midia. O player atualiza o PlaybackStatus com
    /// atraso: lido na hora, um pause aceito ainda dizia "tocando" e o ReceiveMediaStatus
    /// desfazia o botao de play/pause do deck.
    /// </summary>
    public class MediaCommandStateTests
    {
        [Theory]
        // comando, tocava antes, status lido depois, aceito -> tocando
        [InlineData("pause", true, true, true, false)]   // status ainda velho
        [InlineData("play", false, false, true, true)]
        [InlineData("stop", true, true, true, false)]
        [InlineData("playpause", true, true, true, false)]
        [InlineData("toggle", false, false, true, true)]
        [InlineData("playpause", true, false, true, false)] // status ja novo
        [InlineData("pause", true, true, false, true)]   // recusado: fica o que se leu
        [InlineData("next", true, true, true, true)]
        [InlineData("previous", false, false, true, false)]
        public void PlayingAfter_UsesKnownOutcomeWhenStatusIsStale(string command, bool before, bool after, bool accepted, bool expected)
        {
            Assert.Equal(expected, MediaControlService.PlayingAfter(command, before, after, accepted));
        }
    }
}
