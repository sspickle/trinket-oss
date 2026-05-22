var admin  = require('firebase-admin');
var config = require('config');
var path   = require('path');
var fs     = require('fs');

var _app;

function getApp() {
  if (_app) return _app;

  var credential;

  if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
    credential = admin.credential.cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON));
  } else {
    var keyPath = path.join(process.cwd(), 'config/firebase-service-account.json');
    if (fs.existsSync(keyPath)) {
      credential = admin.credential.cert(keyPath);
    } else {
      // On Cloud Run the attached service account covers this via ADC
      credential = admin.credential.applicationDefault();
    }
  }

  _app = admin.initializeApp({
    credential: credential,
    projectId: config.auth.firebase.projectId
  });

  return _app;
}

module.exports = {
  get auth() { return getApp().auth(); }
};
