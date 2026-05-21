var _             = require('underscore'),
    config        = require('config'),
    Boom          = require('@hapi/boom'),
    _request      = require('request'),
    crypto        = require('crypto'),
    userUtil      = require('../util/user');

module.exports = {
  // Google OAuth - optional, only works if configured
  google : function(request, h) {
    if (!config.app.auth || !config.app.auth.google || !config.app.auth.google.clientID) {
      return request.fail({
        message: 'Google OAuth is not configured. Please set up Google OAuth credentials.'
      });
    }

    request.yar.flash('auth', 'Google', true);
    if (request.query.next) {
      request.yar.set('next', request.query.next);
    }

    // Build Google OAuth URL
    var googleAuthUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
    var params = new URLSearchParams({
      client_id: config.app.auth.google.clientID,
      redirect_uri: config.app.auth.google.callbackURL,
      response_type: 'code',
      scope: 'profile email',
      access_type: 'online'
    });

    return request.success({ redirectTo: googleAuthUrl + '?' + params.toString() });
  },

  googleCallback : function(request, h) {
    if (!config.app.auth || !config.app.auth.google || !config.app.auth.google.clientID) {
      return request.fail({
        message: 'Google OAuth is not configured.'
      });
    }

    var code = request.query.code;
    if (!code) {
      return request.fail({ message: 'No authorization code received from Google.' });
    }

    // Exchange code for token
    return new Promise(function(resolve, reject) {
      _request.post({
        url: 'https://oauth2.googleapis.com/token',
        form: {
          code: code,
          client_id: config.app.auth.google.clientID,
          client_secret: config.app.auth.google.clientSecret,
          redirect_uri: config.app.auth.google.callbackURL,
          grant_type: 'authorization_code'
        },
        json: true
      }, function(err, response, body) {
        if (err || !body.access_token) {
          return reject(err || new Error('Failed to get access token: ' + JSON.stringify(body)));
        }
        resolve(body.access_token);
      });
    })
    .then(function(accessToken) {
      // Get user profile
      return new Promise(function(resolve, reject) {
        _request.get({
          url: 'https://www.googleapis.com/oauth2/v2/userinfo',
          headers: { Authorization: 'Bearer ' + accessToken },
          json: true
        }, function(err, response, profile) {
          if (err || !profile.email) {
            return reject(err || new Error('Failed to get user profile'));
          }
          profile.accessToken = accessToken;
          resolve(profile);
        });
      });
    })
    .then(function(profile) {
      // Find or create user
      return new Promise(function(resolve, reject) {
        User.findByMultiple({
          email: profile.email,
          username: userUtil.generate_username(profile.email),
          'profiles.google.id': profile.id
        }, function(err, user) {
          if (err) reject(err);
          else resolve(user);
        });
      })
      .then(function(user) {
        var next = request.yar.get('next');
        var promises = [];
        var updateUser = false;

        request.yar.reset();
        if (next) {
          request.yar.set('next', next);
        }
        request.yar.set('loggedInWith', 'google');

        if (user) {
          request.yar.flash('requested', user.username);
          if (!user.avatar && profile.picture) {
            updateUser = true;
            user.avatar = profile.picture;
          }
          if (!user.profiles) {
            user.profiles = {};
          }
          if (!user.profiles.google) {
            updateUser = true;
            user.profiles.google = {
              id: profile.id,
              token: profile.accessToken
            };
          }

          if (updateUser) {
            promises.push(user.save());
          }

          return Promise.all(promises).then(function() {
            return user;
          });
        }
        else {
          // Create new user
          user = new User();
          user.email = profile.email;
          user.fullname = profile.name || profile.email.split('@')[0];
          user.username = userUtil.generate_username(profile.email);
          request.yar.flash('requested', user.username);
          user.source = 'google';
          user.avatar = profile.picture;
          user.profiles = {
            google: {
              id: profile.id,
              token: profile.accessToken
            }
          };

          return user.save()
            .then(function(newUser) {
              if (!next) {
                request.yar.set('next', '/welcome');
              }
              request.yar.set('grantDemoTrinkets', true);
              request.yar.flash('userAccountCreated', JSON.stringify({}));

              return newUser;
            });
        }
      });
    })
    .then(function(user) {
      // Log in user - store userId in session
      request.yar.set('userId', user.id);
      request.user = user;

      var redirectTo = request.yar.get('next') || '/home';
      request.yar.clear('next');

      var educatorsFormData = request.yar.get('educatorsFormData');
      var registrationPayload = request.yar.get('registration-payload');

      if (educatorsFormData) {
        request.yar.set('educatorsFormData', educatorsFormData, true);
      }
      if (registrationPayload) {
        request.yar.set('registration-payload', registrationPayload);
      }

      // Grant demo trinkets if needed
      if (request.yar.get('grantDemoTrinkets')) {
        request.yar.clear('grantDemoTrinkets');
        // Demo trinket granting would happen here via server.methods
      }

      return request.success({ redirectTo: redirectTo });
    })
    .catch(function(err) {
      log.error('Google OAuth error:', err);
      return request.fail({ message: 'Authentication failed. Please try again.' });
    });
  }
};
