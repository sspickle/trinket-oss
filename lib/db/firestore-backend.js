// Firestore Native backend — translates MongoDB-style queries to Firestore SDK calls.
// Presents the same interface as a Mongoose model so existing class methods
// (bound to {model: <this>}) work without changes.
//
// Not yet implemented — wire config.db.backend = 'firestore' to enable.

function createModel(/* modelName, schema */) {
  throw new Error('Firestore backend not yet implemented');
}

module.exports = { createModel: createModel };
