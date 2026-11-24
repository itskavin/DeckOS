using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>One display boundary for snapshots, hub pushes and onboarding previews.</summary>
    public static class AiAccountDisplay
    {
        public const int AliasMaxLength = 60;

        private static bool Unsafe(char c) => char.IsControl(c) ||
            char.GetUnicodeCategory(c) is UnicodeCategory.Format or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator;

        public static string? ValidateAlias(string? value)
        {
            if (value == null) return null;
            if (value.Length > AliasMaxLength || value.Any(Unsafe)) throw new ArgumentException("Invalid alias.");
            return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        }

        public static string? NormalizeReportedName(string? value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length > 160 || value.Any(Unsafe)) return null;
            return value.Trim();
        }

        // Deliberately excludes name (often an auth filename), id, label, path, raw claims and tokens.
        public static string? ReadReportedName(JsonElement profile)
        {
            if (profile.ValueKind != JsonValueKind.Object) return null;
            foreach (var field in new[] { "display_name", "displayName", "account_name", "email" })
                if (profile.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String &&
                    NormalizeReportedName(value.GetString()) is { } name) return name;
            return null;
        }

        public static void Resolve(AiLimitsAccountDto account, bool hideAccountNames)
        {
            var reported = NormalizeReportedName(account.ReportedName);
            account.HasReportedName = reported != null;
            var fallback = string.IsNullOrWhiteSpace(account.DefaultAlias) ? account.ProviderLabel : account.DefaultAlias;
            account.AutomaticDisplayName = (!hideAccountNames ? reported : null) ?? fallback;
            account.Alias = account.CustomAlias ?? account.AutomaticDisplayName;
            // Raw metadata is never serialized, including in unmasked mode. Only the resolved label leaves the PC.
        }
    }
}
