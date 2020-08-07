import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:firebase_dart/src/auth/rpc/rpc_handler.dart';
import 'package:firebase_dart/src/auth/error.dart';

import 'dart:convert';
import 'dart:async';
import 'package:meta/meta.dart';

import 'jwt_util.dart';
import 'util.dart';

class Tester {
  static const identityToolkitBaseUrl =
      'https://www.googleapis.com/identitytoolkit/v3/relyingparty';

  final String url;
  final dynamic expectedBody;
  final String method;
  final Future Function() action;
  final dynamic Function(Map<String, dynamic>) expectedResult;

  Tester(
      {String path,
      this.expectedBody,
      this.method = 'POST',
      this.action,
      this.expectedResult})
      : url = '$identityToolkitBaseUrl/$path';

  Future<void> shouldSucceed(
      {String url,
      dynamic expectedBody,
      @required FutureOr<Map<String, dynamic>> serverResponse,
      Map<String, String> expectedHeaders,
      Future Function() action,
      dynamic Function(Map<String, dynamic>) expectedResult,
      String method}) async {
    when(method ?? this.method, url ?? this.url)
      ..expectBody(expectedBody ?? this.expectedBody)
      ..expectHeaders(expectedHeaders)
      ..thenReturn(serverResponse);
    var response = await serverResponse;
    expectedResult ??= this.expectedResult ?? (r) async => r;
    var v = await (action ?? this.action)();
    expect(json.decode(json.encode(v)), await expectedResult(response));
  }

  Future<void> shouldFail(
      {String url,
      dynamic expectedBody,
      @required FutureOr<Map<String, dynamic>> serverResponse,
      @required AuthException expectedError,
      Future Function() action,
      String method}) async {
    when(method ?? this.method, url ?? this.url)
      ..expectBody(expectedBody ?? this.expectedBody)
      ..thenReturn(serverResponse);
    expect(action ?? this.action, throwsA(expectedError));
  }

  Future<void> shouldFailWithServerErrors(
      {String url,
      String method,
      Map<String, dynamic> expectedBody,
      Future Function() action,
      @required Map<String, AuthException> errorMap}) async {
    for (var serverErrorCode in errorMap.keys) {
      var expectedError = errorMap[serverErrorCode];

      when(method ?? this.method, url ?? this.url)
        ..expectBody(expectedBody ?? this.expectedBody)
        ..thenReturn(Tester.errorResponse(serverErrorCode));

      var e = await (action ?? this.action)()
          .then<dynamic>((v) => v)
          .catchError((e) => e);
      await expect(e, expectedError);
    }
  }

  static Map<String, dynamic> errorResponse(String message,
          {Map<String, dynamic> extras}) =>
      {
        'error': {
          'errors': [
            {...?extras, 'message': message}
          ],
          'code': 400,
          'message': message
        }
      };
}

void main() {
  mockOpenidResponses();

  group('RpcHandler', () {
    var rpcHandler = RpcHandler('apiKey', httpClient: mockHttpClient);

    var pendingCredResponse = {
      'mfaInfo': {
        'mfaEnrollmentId': 'ENROLLMENT_UID1',
        'enrolledAt': clock.now().toIso8601String(),
        'phoneInfo': '+16505551234'
      },
      'mfaPendingCredential': 'PENDING_CREDENTIAL'
    };

    setUp(() {
      rpcHandler..tenantId = null;
    });

    group('identitytoolkit', () {
      group('identitytoolkit general', () {
        var tester = Tester(
          path: 'signupNewUser',
          expectedBody: {'returnSecureToken': true},
          expectedResult: (response) => {'id_token': response['idToken']},
          action: () => rpcHandler
              .signInAnonymously()
              .then((v) => {'id_token': v.response['id_token']}),
        );
        group('server provided error message', () {
          test('server provided error message: known error code', () async {
            // Test when server returns an error message with the details appended:
            // INVALID_CUSTOM_TOKEN : [error detail here]
            // The above error message should generate an Auth error with code
            // client equivalent of INVALID_CUSTOM_TOKEN and the message:
            // [error detail here]
            await tester.shouldFail(
              serverResponse: Tester.errorResponse(
                  'INVALID_CUSTOM_TOKEN : Some specific reason.',
                  extras: {
                    'domain': 'global',
                    'reason': 'invalid',
                  }),
              expectedError: AuthException.invalidCustomToken()
                  .replace(message: 'Some specific reason.'),
            );
          });

          test('server provided error message: unknown error code', () async {
            // Test when server returns an error message with the details appended:
            // UNKNOWN_CODE : [error detail here]
            // The above error message should generate an Auth error with internal-error
            // ccode and the message:
            // [error detail here]
            await tester.shouldFail(
              serverResponse: Tester.errorResponse(
                  'WHAAAAAT?: Something strange happened.',
                  extras: {
                    'domain': 'global',
                    'reason': 'invalid',
                  }),
              expectedError: AuthException.internalError()
                  .replace(message: 'Something strange happened.'),
            );
          });

          test('server provided error message: no error code', () async {
            // Test when server returns an unexpected error message with a colon in the
            // message field that it does not treat the string after the colon as the
            // detailed error message. Instead the whole response should be serialized.
            var serverResponse = Tester.errorResponse(
                'Error getting access token from FACEBOOK, response: OA'
                'uth2TokenResponse{params: %7B%22error%22:%7B%22message%22:%22This+IP+'
                'can\'t+make+requests+for+that+application.%22,%22type%22:%22OAuthExce'
                'ption%22,%22code%22:5,%22fbtrace_id%22:%22AHHaoO5cS1K%22%7D%7D&error='
                'OAuthException&error_description=This+IP+can\'t+make+requests+for+tha'
                't+application., httpMetadata: HttpMetadata{status=400, cachePolicy=NO'
                '_CACHE, cacheDuration=null, staleWhileRevalidate=null, filename=null,'
                'lastModified=null, headers=HTTP/1.1 200 OK\r\n\r\n, cookieList=[]}}, '
                'OAuth2 redirect uri is: https://example12345.firebaseapp.com/__/auth/'
                'handler',
                extras: {
                  'domain': 'global',
                  'reason': 'invalid',
                });
            await tester.shouldFail(
              serverResponse: serverResponse,
              expectedError: AuthException.internalError()
                  .replace(message: json.encode(serverResponse)),
            );
          });
        });
        group('unexpected Apiary error', () {
          test('unexpected Apiary error', () async {
            // Test when an unexpected Apiary error is returned that serialized server
            // response is used as the client facing error message.

            // Server response.
            var serverResponse = Tester.errorResponse('Bad Request', extras: {
              'domain': 'usageLimits',
              'reason': 'keyExpired',
            });

            await tester.shouldFail(
              serverResponse: serverResponse,
              expectedError: AuthException.internalError()
                  .replace(message: json.encode(serverResponse)),
            );
          });
        });
      });

      group('getAuthorizedDomains', () {
        var tester = Tester(
            path: 'getProjectConfig',
            expectedBody: null,
            expectedResult: (response) => response['authorizedDomains'],
            action: () => rpcHandler.getAuthorizedDomains(),
            method: 'GET');

        test('getAuthorizedDomains: success', () async {
          await tester.shouldSucceed(
            serverResponse: {
              'authorizedDomains': ['domain.com', 'www.mydomain.com']
            },
          );
        });
      });

      group('getAccountInfoByIdToken', () {
        var tester = Tester(
          path: 'getAccountInfo',
          expectedBody: {'idToken': 'ID_TOKEN'},
          action: () => rpcHandler.getAccountInfoByIdToken('ID_TOKEN'),
        );
        test('getAccountInfoByIdToken: success', () async {
          await tester.shouldSucceed(
            serverResponse: {
              'users': [
                {
                  'localId': '14584746072031976743',
                  'email': 'uid123@fake.com',
                  'emailVerified': true,
                  'displayName': 'John Doe',
                  'providerUserInfo': [
                    {
                      'providerId': 'google.com',
                      'displayName': 'John Doe',
                      'photoUrl':
                          'https://lh5.googleusercontent.com/123456789/photo.jpg',
                      'federatedId': 'https://accounts.google.com/123456789'
                    },
                    {
                      'providerId': 'twitter.com',
                      'displayName': 'John Doe',
                      'photoUrl':
                          'http://abs.twimg.com/sticky/default_profile_images/def'
                              'ault_profile_3_normal.png',
                      'federatedId': 'http://twitter.com/987654321'
                    }
                  ],
                  'photoUrl': 'http://abs.twimg.com/sticky/photo.png',
                  'passwordUpdatedAt': 0.0,
                  'disabled': false
                }
              ]
            },
          );
        });
      });
      group('verifyPassword', () {
        var tester = Tester(
            path: 'verifyPassword',
            expectedBody: {
              'email': 'uid123@fake.com',
              'password': 'mysupersecretpassword',
              'returnSecureToken': true
            },
            expectedResult: (response) {
              return {'id_token': response['idToken']};
            },
            action: () => rpcHandler
                .verifyPassword('uid123@fake.com', 'mysupersecretpassword')
                .then((v) => {'id_token': v.response['id_token']}));
        test('verifyPassword: success', () async {
          await tester.shouldSucceed(
            serverResponse: {
              'idToken': createMockJwt(uid: 'uid123', providerId: 'password')
            },
          );
        });

        test('verifyPassword: multi factor required', () async {
          await tester.shouldFail(
            expectedError: AuthException.mfaRequired(),
            serverResponse: pendingCredResponse,
          );
        });

        test('verifyPassword: tenant id', () async {
          rpcHandler.tenantId = '123456789012';
          await tester.shouldSucceed(
            expectedBody: {
              'email': 'uid123@fake.com',
              'password': 'mysupersecretpassword',
              'returnSecureToken': true,
              'tenantId': '123456789012'
            },
            serverResponse: {
              'idToken': createMockJwt(uid: 'uid123', providerId: 'password')
            },
          );
        });

        test('verifyPassword: server caught error', () async {
          await tester.shouldFailWithServerErrors(
            errorMap: {
              'INVALID_EMAIL': AuthException.invalidEmail(),
              'INVALID_PASSWORD': AuthException.invalidPassword(),
              'TOO_MANY_ATTEMPTS_TRY_LATER':
                  AuthException.tooManyAttemptsTryLater(),
              'USER_DISABLED': AuthException.userDisabled(),
              'INVALID_TENANT_ID': AuthException.invalidTenantId(),
            },
          );
        });

        test('verifyPassword: unknown server response', () async {
          await tester.shouldFail(
            expectedBody: {
              'email': 'uid123@fake.com',
              'password': 'mysupersecretpassword',
              'returnSecureToken': true
            },
            serverResponse: {},
            expectedError: AuthException.internalError(),
            action: () => rpcHandler.verifyPassword(
                'uid123@fake.com', 'mysupersecretpassword'),
          );
        });

        test('verifyPassword: invalid password request', () async {
          expect(() => rpcHandler.verifyPassword('uid123@fake.com', ''),
              throwsA(AuthException.invalidPassword()));
        });

        test('verifyPassword: invalid email error', () async {
          // Test when invalid email is passed in verifyPassword request.
          // Test when request is invalid.
          expect(
              () => rpcHandler.verifyPassword(
                  'uid123.invalid', 'mysupersecretpassword'),
              throwsA(AuthException.invalidEmail()));
        });
      });

      group('signInAnonymously', () {
        var tester = Tester(
          path: 'signupNewUser',
          expectedBody: {'returnSecureToken': true},
          expectedResult: (response) => {'id_token': response['idToken']},
          action: () => rpcHandler
              .signInAnonymously()
              .then((v) => {'id_token': v.response['id_token']}),
        );
        test('signInAnonymously: success', () async {
          await tester.shouldSucceed(
            serverResponse: {
              'idToken': createMockJwt(
                  uid: generateRandomString(24), providerId: 'anonymous')
            },
          );
        });
        test('signInAnonymously: tenant id', () async {
          rpcHandler.tenantId = '123456789012';
          await tester.shouldSucceed(
            expectedBody: {
              'returnSecureToken': true,
              'tenantId': '123456789012'
            },
            serverResponse: {
              'idToken': createMockJwt(
                  uid: generateRandomString(24), providerId: 'anonymous')
            },
          );
        });
        test('signInAnonymously: unsupported tenant operation', () async {
          rpcHandler.tenantId = '123456789012';
          await tester.shouldFailWithServerErrors(
            expectedBody: {
              'returnSecureToken': true,
              'tenantId': '123456789012'
            },
            errorMap: {
              'UNSUPPORTED_TENANT_OPERATION':
                  AuthException.unsupportedTenantOperation(),
            },
          );
        });
        test('signInAnonymously: unknown server response', () async {
          // Test when server returns unexpected response with no error message.
          await tester.shouldFail(
            serverResponse: {},
            expectedError: AuthException.internalError(),
          );
        });
      });
    });
  });
}
