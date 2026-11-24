/**
 * Repository abstraction & in-memory reference implementation for DeckOS
 * billing verification state.
 *
 * Production deployments should replace `InMemoryBillingRecordStore` with a
 * durable database (e.g. Postgres / SQLite / DynamoDB) implementing the same
 * methods. Raw `purchaseToken` values should be encrypted at rest in the DB
 * and NEVER written to logs or returned in client responses.
 */
export class InMemoryBillingRecordStore {
  constructor() {
    this._byTokenHash = new Map();
    this._byEntitlementId = new Map();
    this._processedRtdnIds = new Set();
  }

  async getByTokenHash(tokenHash) {
    return this._byTokenHash.get(tokenHash) ?? null;
  }

  async getByEntitlementId(entitlementId) {
    return this._byEntitlementId.get(entitlementId) ?? null;
  }

  async saveRecord(record) {
    this._byTokenHash.set(record.tokenHash, { ...record });
    this._byEntitlementId.set(record.entitlementId, { ...record });
  }

  async hasProcessedRtdn(messageId) {
    return this._processedRtdnIds.has(messageId);
  }

  async markRtdnProcessed(messageId) {
    this._processedRtdnIds.add(messageId);
  }
}
