/**
 * Google Play Real-time Developer Notifications (RTDN) parser & Pub/Sub push
 * handler.
 *
 * Official RTDN SubscriptionNotification types:
 *  1  SUBSCRIPTION_RECOVERED
 *  2  SUBSCRIPTION_RENEWED
 *  3  SUBSCRIPTION_CANCELED
 *  4  SUBSCRIPTION_PURCHASED
 *  5  SUBSCRIPTION_ON_HOLD
 *  6  SUBSCRIPTION_IN_GRACE_PERIOD
 *  7  SUBSCRIPTION_RESTARTED
 *  8  SUBSCRIPTION_PRICE_CHANGE_CONFIRMED (deprecated)
 *  9  SUBSCRIPTION_DEFERRED
 * 10  SUBSCRIPTION_PAUSED
 * 11  SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED
 * 12  SUBSCRIPTION_REVOKED
 * 13  SUBSCRIPTION_EXPIRED
 * 20  SUBSCRIPTION_PENDING_PURCHASE_CANCELED
 */

export const RTDN_SUBSCRIPTION_TYPES = Object.freeze({
  1: 'SUBSCRIPTION_RECOVERED',
  2: 'SUBSCRIPTION_RENEWED',
  3: 'SUBSCRIPTION_CANCELED',
  4: 'SUBSCRIPTION_PURCHASED',
  5: 'SUBSCRIPTION_ON_HOLD',
  6: 'SUBSCRIPTION_IN_GRACE_PERIOD',
  7: 'SUBSCRIPTION_RESTARTED',
  8: 'SUBSCRIPTION_PRICE_CHANGE_CONFIRMED',
  9: 'SUBSCRIPTION_DEFERRED',
  10: 'SUBSCRIPTION_PAUSED',
  11: 'SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED',
  12: 'SUBSCRIPTION_REVOKED',
  13: 'SUBSCRIPTION_EXPIRED',
  20: 'SUBSCRIPTION_PENDING_PURCHASE_CANCELED',
});

/**
 * Decodes a Google Cloud Pub/Sub push HTTP JSON envelope containing a base64
 * Google Play DeveloperNotification payload.
 */
export function parsePubSubRtdnBody(body) {
  const message = body?.message;
  if (!message || typeof message.data !== 'string' || !message.messageId) {
    throw new Error('Invalid Pub/Sub push envelope');
  }
  const decodedJson = Buffer.from(message.data, 'base64').toString('utf8');
  const notification = JSON.parse(decodedJson);
  if (!notification || typeof notification.packageName !== 'string') {
    throw new Error('Invalid DeveloperNotification payload');
  }

  return {
    messageId: String(message.messageId),
    publishTime: message.publishTime ?? null,
    packageName: notification.packageName,
    eventTimeMillis: Number(notification.eventTimeMillis ?? 0),
    testNotification: notification.testNotification ?? null,
    subscriptionNotification: notification.subscriptionNotification
      ? {
          version: notification.subscriptionNotification.version ?? '1.0',
          notificationType: Number(
            notification.subscriptionNotification.notificationType,
          ),
          notificationTypeName:
            RTDN_SUBSCRIPTION_TYPES[
              Number(notification.subscriptionNotification.notificationType)
            ] ?? 'UNKNOWN',
          purchaseToken: String(
            notification.subscriptionNotification.purchaseToken ?? '',
          ),
          subscriptionId: String(
            notification.subscriptionNotification.subscriptionId ?? '',
          ),
        }
      : null,
  };
}
