/// Localized strings for DeckOS Subscription / Play Billing UI.
///
/// Defaults to English (`en`) and includes Portuguese (`pt`) and Spanish (`es`)
/// translations matching DeckOS's `AppLanguage.current` without introducing
/// unmerged literal `tr(...)` keys during parallel work.
library;

import 'package:deckos/core/i18n/i18n.dart';

/// Looks up a billing UI string for the active [AppLanguage], defaulting to
/// English.
abstract final class BillingStrings {
  static String t(String key, [Map<String, Object?> args = const {}]) {
    final lang = AppLanguage.current.value;
    final table = switch (lang) {
      'pt' => _pt,
      'es' => _es,
      _ => _en,
    };
    var value = table[key] ?? _en[key] ?? key;
    args.forEach((k, v) => value = value.replaceAll('{$k}', '${v ?? ''}'));
    return value;
  }

  static const Map<String, String> _en = <String, String>{
    'pageTitle': 'Subscription',
    'settingsSubtitle': 'Manage DeckOS subscription and Google Play billing',
    'heroTitle': 'DeckOS Subscription',
    'statusUnconfigured': 'Not available yet',
    'statusUnsupportedPlatform': 'Android only',
    'statusFree': 'Free plan',
    'statusPending': 'Payment pending',
    'statusActive': 'Active',
    'statusGracePeriod': 'Payment issue (grace period)',
    'statusOnHold': 'Account hold',
    'statusPaused': 'Paused',
    'statusCanceledActive': 'Canceled · active until {date}',
    'statusExpired': 'Expired',
    'statusRevoked': 'Refunded or revoked',
    'detailUnconfigured':
        'Subscription plans are not configured in Google Play yet. Existing features remain available.',
    'detailUnsupportedPlatform':
        'Subscriptions are billed through Google Play on Android devices. Purchase actions are disabled on this platform.',
    'detailFree':
        'No active DeckOS subscription on this device. Security and privacy controls are always free.',
    'detailPending':
        'Google Play is still confirming your payment. Access activates automatically once payment completes and is verified.',
    'detailActiveRenews':
        'Auto-renews via Google Play · current period ends {date}.',
    'detailActive': 'Verified via Google Play.',
    'detailGracePeriod':
        'Google Play could not process your renewal. Update your payment method in Google Play to keep access uninterrupted.',
    'detailOnHold':
        'Your subscription is on hold due to a payment issue. Fix your payment method in Google Play to restore access.',
    'detailPaused':
        'Your subscription is paused in Google Play. Resume it in Google Play when you are ready.',
    'detailCanceledActive':
        'Auto-renewal is off. Access stays active until {date}.',
    'detailExpired':
        'Your previous subscription ended. You can resubscribe anytime once plans are available.',
    'detailRevoked':
        'This subscription was refunded or revoked in Google Play.',
    'offlineNotice':
        'Offline mode: showing your last verified status (valid until {date}). Reconnect to refresh.',
    'plansHeader': 'Plans',
    'plansLoading': 'Loading plans from Google Play…',
    'plansUnavailableTitle': 'Plans are not available yet',
    'plansUnavailableBody':
        'Google Play pricing will appear here once subscription products are published. No charges can be made right now.',
    'plansMissingSkuBody':
        'Subscription products were not returned by Google Play yet. Check back later or restore an existing purchase.',
    'plansSelectPrompt': 'Choose a plan below. Nothing is preselected.',
    'intervalMonthly': 'Monthly',
    'intervalYearly': 'Yearly',
    'periodPerMonth': 'per month',
    'periodPerYear': 'per year',
    'periodRecurring': 'recurring',
    'savingsBadge': 'Save {percent}%',
    'freeTrialBadge': 'Includes {period} free trial',
    'introOfferBadge': 'Intro offer: {price}',
    'selectedLabel': 'Selected',
    'subscribeButton': 'Subscribe via Google Play',
    'subscribeSelectFirst': 'Select a plan to continue',
    'subscribeUnavailableButton': 'Subscriptions unavailable',
    'restoreButton': 'Restore purchases',
    'refreshButton': 'Refresh status',
    'manageButton': 'Manage or cancel in Google Play',
    'actionsHeader': 'Manage',
    'termsHeader': 'Billing terms & cancellation',
    'termsRecurring':
        'Subscriptions are billed and renewed automatically through your Google Play account at the localized price and interval shown above until canceled.',
    'termsCancel':
        'Cancel anytime before renewal in Google Play → Payments & subscriptions → Subscriptions, or by tapping "Manage or cancel in Google Play" above.',
    'termsSecurity':
        'Purchase verification uses a trusted server check against Google Play. Your local PC companion never processes payments. Security and privacy controls remain free.',
    'termsPublisher': 'Published by Bytetrix · Support: contact@kavin.sh',
    'fbNotConfigured':
        'Subscriptions are not configured yet. No purchase was started.',
    'fbUnsupportedPlatform':
        'Google Play Billing is only available on Android devices.',
    'fbStoreUnavailable':
        'Google Play Store is currently unavailable on this device. Make sure Play Store is installed and signed in.',
    'fbMissingProducts':
        'Subscription plans are not available from Google Play yet.',
    'fbOffline':
        'No internet connection. Connect to the internet to load plans or verify purchases.',
    'fbOfflineCacheExpired':
        'Offline verification window expired. Connect to the internet to refresh your subscription status.',
    'fbAlreadyOwned':
        'Google Play reports you already own this subscription. Tap "Restore purchases" to sync your status.',
    'fbUserCanceled': 'Purchase canceled. You were not charged.',
    'fbPendingPayment':
        'Payment is pending confirmation from Google Play. Access will activate after verification.',
    'fbVerificationFailed':
        'Could not verify the purchase with the billing server. Your purchase is not lost—try refreshing once online.',
    'fbInvalidSignature':
        'Entitlement verification signature could not be trusted. Refresh online or contact contact@kavin.sh.',
    'fbRestoreSucceeded': 'Subscription status synced with Google Play.',
    'fbRestoreEmpty':
        'No active DeckOS subscription was found for this Google Play account.',
    'fbPurchaseVerified': 'Subscription verified and active.',
    'fbManageLinkFailed':
        'Could not open Google Play. Open the Play Store app → Payments & subscriptions → Subscriptions.',
    'fbUnknownError':
        'Something went wrong with Google Play billing. Please try again.',
    'periodDays': '{n} days',
    'periodWeeks': '{n} weeks',
    'periodMonths': '{n} months',
    'periodYears': '{n} years',
  };

  static const Map<String, String> _pt = <String, String>{
    'pageTitle': 'Assinatura',
    'settingsSubtitle':
        'Gerencie a assinatura do DeckOS e cobrança no Google Play',
    'heroTitle': 'Assinatura DeckOS',
    'statusUnconfigured': 'Ainda indisponível',
    'statusUnsupportedPlatform': 'Somente Android',
    'statusFree': 'Plano gratuito',
    'statusPending': 'Pagamento pendente',
    'statusActive': 'Ativa',
    'statusGracePeriod': 'Problema no pagamento (carência)',
    'statusOnHold': 'Conta suspensa',
    'statusPaused': 'Pausada',
    'statusCanceledActive': 'Cancelada · ativa até {date}',
    'statusExpired': 'Expirada',
    'statusRevoked': 'Reembolsada ou revogada',
    'detailUnconfigured':
        'Os planos de assinatura ainda não estão configurados no Google Play. Os recursos atuais continuam disponíveis.',
    'detailUnsupportedPlatform':
        'As assinaturas são cobradas pelo Google Play em aparelhos Android. A compra fica desativada nesta plataforma.',
    'detailFree':
        'Nenhuma assinatura ativa neste aparelho. Controles de segurança e privacidade são sempre gratuitos.',
    'detailPending':
        'O Google Play ainda está confirmando o pagamento. O acesso será liberado após a verificação.',
    'detailActiveRenews':
        'Renovação automática pelo Google Play · período atual até {date}.',
    'detailActive': 'Verificada pelo Google Play.',
    'detailGracePeriod':
        'O Google Play não conseguiu cobrar a renovação. Atualize sua forma de pagamento no Google Play.',
    'detailOnHold':
        'Sua assinatura está em espera por falha de pagamento. Corrija no Google Play para retomar o acesso.',
    'detailPaused':
        'Sua assinatura está pausada no Google Play. Retome pelo Google Play quando quiser.',
    'detailCanceledActive':
        'Renovação automática desativada. O acesso continua até {date}.',
    'detailExpired':
        'Sua assinatura anterior terminou. Você pode assinar novamente quando os planos estiverem disponíveis.',
    'detailRevoked':
        'Esta assinatura foi reembolsada ou revogada no Google Play.',
    'offlineNotice':
        'Modo offline: mostrando último status verificado (válido até {date}). Conecte-se para atualizar.',
    'plansHeader': 'Planos',
    'plansLoading': 'Carregando planos do Google Play…',
    'plansUnavailableTitle': 'Planos ainda não disponíveis',
    'plansUnavailableBody':
        'Os preços do Google Play aparecerão aqui quando os produtos de assinatura forem publicados. Nenhuma cobrança pode ser feita agora.',
    'plansMissingSkuBody':
        'O Google Play ainda não retornou produtos de assinatura. Tente novamente mais tarde ou restaure uma compra.',
    'plansSelectPrompt':
        'Escolha um plano abaixo. Nenhum plano vem pré-selecionado.',
    'intervalMonthly': 'Mensal',
    'intervalYearly': 'Anual',
    'periodPerMonth': 'por mês',
    'periodPerYear': 'por ano',
    'periodRecurring': 'recorrente',
    'savingsBadge': 'Economize {percent}%',
    'freeTrialBadge': 'Inclui teste grátis de {period}',
    'introOfferBadge': 'Oferta inicial: {price}',
    'selectedLabel': 'Selecionado',
    'subscribeButton': 'Assinar pelo Google Play',
    'subscribeSelectFirst': 'Selecione um plano para continuar',
    'subscribeUnavailableButton': 'Assinaturas indisponíveis',
    'restoreButton': 'Restaurar compras',
    'refreshButton': 'Atualizar status',
    'manageButton': 'Gerenciar ou cancelar no Google Play',
    'actionsHeader': 'Gerenciar',
    'termsHeader': 'Cobrança recorrente e cancelamento',
    'termsRecurring':
        'As assinaturas são cobradas e renovadas automaticamente pela sua conta Google Play no valor e período exibidos acima até o cancelamento.',
    'termsCancel':
        'Cancele quando quiser antes da renovação em Google Play → Pagamentos e assinaturas → Assinaturas, ou tocando em "Gerenciar ou cancelar no Google Play" acima.',
    'termsSecurity':
        'A verificação da compra usa validação em servidor confiável junto ao Google Play. O programa do PC não processa pagamentos. Segurança e privacidade continuam gratuitas.',
    'termsPublisher': 'Publicado por Bytetrix · Suporte: contact@kavin.sh',
    'fbNotConfigured':
        'As assinaturas ainda não estão configuradas. Nenhuma compra foi iniciada.',
    'fbUnsupportedPlatform':
        'A cobrança do Google Play está disponível apenas no Android.',
    'fbStoreUnavailable':
        'A Google Play Store está indisponível neste aparelho.',
    'fbMissingProducts':
        'Os planos ainda não estão disponíveis no Google Play.',
    'fbOffline':
        'Sem conexão com a internet. Conecte-se para carregar planos ou verificar compras.',
    'fbOfflineCacheExpired':
        'A janela offline expirou. Conecte-se à internet para atualizar o status.',
    'fbAlreadyOwned':
        'O Google Play indica que você já possui esta assinatura. Toque em "Restaurar compras".',
    'fbUserCanceled': 'Compra cancelada. Nenhuma cobrança foi feita.',
    'fbPendingPayment':
        'Pagamento pendente no Google Play. O acesso será liberado após confirmação.',
    'fbVerificationFailed':
        'Não foi possível verificar a compra no servidor. Tente atualizar quando estiver online.',
    'fbInvalidSignature':
        'A assinatura de verificação não pôde ser validada. Atualize online ou contate contact@kavin.sh.',
    'fbRestoreSucceeded':
        'Status da assinatura sincronizado com o Google Play.',
    'fbRestoreEmpty':
        'Nenhuma assinatura ativa do DeckOS encontrada nesta conta Google Play.',
    'fbPurchaseVerified': 'Assinatura verificada e ativa.',
    'fbManageLinkFailed':
        'Não foi possível abrir o Google Play. Abra a Play Store → Pagamentos e assinaturas → Assinaturas.',
    'fbUnknownError':
        'Algo deu errado com a cobrança do Google Play. Tente novamente.',
    'periodDays': '{n} dias',
    'periodWeeks': '{n} semanas',
    'periodMonths': '{n} meses',
    'periodYears': '{n} anos',
  };

  static const Map<String, String> _es = <String, String>{
    'pageTitle': 'Suscripción',
    'settingsSubtitle': 'Administra la suscripción de DeckOS y Google Play',
    'heroTitle': 'Suscripción de DeckOS',
    'statusUnconfigured': 'Aún no disponible',
    'statusUnsupportedPlatform': 'Solo Android',
    'statusFree': 'Plan gratuito',
    'statusPending': 'Pago pendiente',
    'statusActive': 'Activa',
    'statusGracePeriod': 'Problema de pago (periodo de gracia)',
    'statusOnHold': 'Cuenta en espera',
    'statusPaused': 'Pausada',
    'statusCanceledActive': 'Cancelada · activa hasta {date}',
    'statusExpired': 'Expirada',
    'statusRevoked': 'Reembolsada o revocada',
    'detailUnconfigured':
        'Los planes de suscripción aún no están configurados en Google Play. Las funciones actuales siguen disponibles.',
    'detailUnsupportedPlatform':
        'Las suscripciones se cobran mediante Google Play en dispositivos Android. Las compras están deshabilitadas en esta plataforma.',
    'detailFree':
        'No hay ninguna suscripción activa en este dispositivo. Los controles de seguridad y privacidad son siempre gratuitos.',
    'detailPending':
        'Google Play aún está confirmando tu pago. El acceso se activará automáticamente tras la verificación.',
    'detailActiveRenews':
        'Se renueva automáticamente en Google Play · periodo actual hasta {date}.',
    'detailActive': 'Verificada mediante Google Play.',
    'detailGracePeriod':
        'Google Play no pudo procesar la renovación. Actualiza tu método de pago en Google Play.',
    'detailOnHold':
        'Tu suscripción está en espera por un problema de pago. Corrígelo en Google Play para recuperar el acceso.',
    'detailPaused':
        'Tu suscripción está pausada en Google Play. Reanúdala desde Google Play cuando quieras.',
    'detailCanceledActive':
        'La renovación automática está desactivada. El acceso sigue activo hasta {date}.',
    'detailExpired':
        'Tu suscripción anterior finalizó. Puedes volver a suscribirte cuando los planes estén disponibles.',
    'detailRevoked':
        'Esta suscripción fue reembolsada o revocada en Google Play.',
    'offlineNotice':
        'Modo sin conexión: mostrando el último estado verificado (válido hasta {date}). Conéctate para actualizar.',
    'plansHeader': 'Planes',
    'plansLoading': 'Cargando planes desde Google Play…',
    'plansUnavailableTitle': 'Los planes aún no están disponibles',
    'plansUnavailableBody':
        'Los precios de Google Play aparecerán aquí cuando se publiquen los productos de suscripción. No se realizará ningún cobro ahora.',
    'plansMissingSkuBody':
        'Google Play aún no devolvió productos de suscripción. Vuelve a intentarlo más tarde o restaura una compra.',
    'plansSelectPrompt': 'Elige un plan abajo. Ninguno está preseleccionado.',
    'intervalMonthly': 'Mensual',
    'intervalYearly': 'Anual',
    'periodPerMonth': 'al mes',
    'periodPerYear': 'al año',
    'periodRecurring': 'recurrente',
    'savingsBadge': 'Ahorra {percent}%',
    'freeTrialBadge': 'Incluye prueba gratuita de {period}',
    'introOfferBadge': 'Oferta inicial: {price}',
    'selectedLabel': 'Seleccionado',
    'subscribeButton': 'Suscribirse con Google Play',
    'subscribeSelectFirst': 'Selecciona un plan para continuar',
    'subscribeUnavailableButton': 'Suscripciones no disponibles',
    'restoreButton': 'Restaurar compras',
    'refreshButton': 'Actualizar estado',
    'manageButton': 'Administrar o cancelar en Google Play',
    'actionsHeader': 'Administrar',
    'termsHeader': 'Términos de facturación y cancelación',
    'termsRecurring':
        'Las suscripciones se cobran y renuevan automáticamente a través de tu cuenta de Google Play al precio y periodo mostrados arriba hasta que canceles.',
    'termsCancel':
        'Cancela en cualquier momento antes de la renovación en Google Play → Pagos y suscripciones → Suscripciones, o tocando "Administrar o cancelar en Google Play" arriba.',
    'termsSecurity':
        'La verificación de compras se realiza en un servidor confiable contra Google Play. El programa del PC no procesa pagos. Seguridad y privacidad siguen siendo gratuitas.',
    'termsPublisher': 'Publicado por Bytetrix · Soporte: contact@kavin.sh',
    'fbNotConfigured':
        'Las suscripciones aún no están configuradas. No se inició ninguna compra.',
    'fbUnsupportedPlatform':
        'La facturación de Google Play solo está disponible en dispositivos Android.',
    'fbStoreUnavailable':
        'Google Play Store no está disponible en este dispositivo.',
    'fbMissingProducts':
        'Los planes de suscripción aún no están disponibles en Google Play.',
    'fbOffline':
        'Sin conexión a internet. Conéctate para cargar planes o verificar compras.',
    'fbOfflineCacheExpired':
        'La ventana sin conexión expiró. Conéctate a internet para actualizar el estado.',
    'fbAlreadyOwned':
        'Google Play indica que ya tienes esta suscripción. Toca "Restaurar compras".',
    'fbUserCanceled': 'Compra cancelada. No se realizó ningún cargo.',
    'fbPendingPayment':
        'Pago pendiente de confirmación en Google Play. El acceso se activará tras la verificación.',
    'fbVerificationFailed':
        'No se pudo verificar la compra con el servidor. Intenta actualizar cuando tengas conexión.',
    'fbInvalidSignature':
        'No se pudo validar la firma de verificación. Actualiza con conexión o escribe a contact@kavin.sh.',
    'fbRestoreSucceeded':
        'Estado de la suscripción sincronizado con Google Play.',
    'fbRestoreEmpty':
        'No se encontró ninguna suscripción activa de DeckOS en esta cuenta de Google Play.',
    'fbPurchaseVerified': 'Suscripción verificada y activa.',
    'fbManageLinkFailed':
        'No se pudo abrir Google Play. Abre Play Store → Pagos y suscripciones → Suscripciones.',
    'fbUnknownError':
        'Ocurrió un error con la facturación de Google Play. Inténtalo de nuevo.',
    'periodDays': '{n} días',
    'periodWeeks': '{n} semanas',
    'periodMonths': '{n} meses',
    'periodYears': '{n} años',
  };

  /// Formats an ISO-8601 duration returned by Play (e.g. `P7D`, `P1M`, `P1Y`).
  static String formatIsoPeriod(String iso) {
    final m = RegExp(r'^P(\d+)([DWMY])$').firstMatch(iso.trim().toUpperCase());
    if (m == null) return iso;
    final n = m.group(1)!;
    final unit = m.group(2)!;
    return switch (unit) {
      'D' => t('periodDays', {'n': n}),
      'W' => t('periodWeeks', {'n': n}),
      'M' => t('periodMonths', {'n': n}),
      'Y' => t('periodYears', {'n': n}),
      _ => iso,
    };
  }
}
