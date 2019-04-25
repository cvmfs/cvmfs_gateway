package frontend

import (
	"bytes"
	"encoding/base64"
	"io"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	gw "github.com/cvmfs/gateway/internal/gateway"
	be "github.com/cvmfs/gateway/internal/gateway/backend"
)

// MakeAuthzMiddleware returns an HMAC authorization middleware for use with the gorilla/mux server
func MakeAuthzMiddleware(ac *be.AccessConfig) mux.MiddlewareFunc {
	return mux.MiddlewareFunc(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			// GET requests do not need authorization
			if req.Method == "GET" {
				next.ServeHTTP(w, req)
				return
			}

			reqID, _ := req.Context().Value(idKey).(uuid.UUID)
			tokens := strings.Split(req.Header.Get("Authorization"), " ")
			if len(tokens) != 2 {
				gw.Log.Error().
					Str("component", "http").
					Str("req_id", reqID.String()).
					Msg("missing tokens in authorization header")
				replyJSON(&reqID, w, message{"status": "error", "reason": "invalid_hmac"})
				return
			}

			keyID := tokens[0]
			HMAC, err := base64.StdEncoding.DecodeString(tokens[1])
			if err != nil {
				gw.Log.Error().
					Str("component", "http").
					Str("req_id", reqID.String()).
					Err(err).Msg("could not base64 decode HMAC")
				replyJSON(&reqID, w, message{"status": "error", "reason": "invalid_hmac"})
				return
			}

			secret := ac.GetSecret(keyID)
			if len(secret) == 0 {
				gw.Log.Error().
					Str("component", "http").
					Str("req_id", reqID.String()).
					Msg("invalid key ID specified")
				replyJSON(&reqID, w, message{"status": "error", "reason": "invalid_hmac"})
				return
			}

			// Different parts of the request are used to compute then HMAC, depending
			// in HTTP method and route

			var HMACInput []byte
			if strings.HasPrefix(req.URL.Path, APIRoot+"/leases") {
				token, _ := mux.Vars(req)["token"]
				if token != "" {
					// For commit/drop lease requests use the token to compute HMAC
					HMACInput = []byte(token)
				} else {
					// For new lease request used the request body to compute HMAC
					HMACInput, err = ioutil.ReadAll(req.Body)
					if err != nil {
						httpWrapError(&reqID, err, "could not read request body", w, http.StatusInternalServerError)
						return
					}
					// Body needs to be read again in the next handler, reset it
					// using a copy of the original body
					bodyCopy := ioutil.NopCloser(bytes.NewReader(HMACInput))
					req.Body.Close()
					req.Body = bodyCopy
				}
			} else if strings.HasPrefix(req.URL.Path, APIRoot+"/payloads") {
				token, _ := mux.Vars(req)["token"]
				if token != "" {
					// For the new style of payload submission requests, use the token to compute HMAC
					HMACInput = []byte(token)
				} else {
					// For legacy payload submission requests, the JSON msg at the beginning of the body
					// is used to compute the HMAC
					msgSize, err := strconv.Atoi(req.Header.Get("message-size"))
					if err != nil {
						httpWrapError(&reqID, err, "missing message-size header", w, http.StatusBadRequest)
						return
					}
					msgRdr := io.LimitReader(req.Body, int64(msgSize))
					msg, err := ioutil.ReadAll(msgRdr)
					if err != nil {
						httpWrapError(&reqID, err, "invalid request body", w, http.StatusBadRequest)
						return
					}

					HMACInput = msg

					// replace the request body with a new ReadCLoser which includes the already-read
					// head part
					req.Body = newRecombineReadCloser(msg, req.Body)
				}
			}

			if !CheckHMAC(HMACInput, HMAC, secret) {
				gw.Log.Error().
					Str("component", "http").
					Str("req_id", reqID.String()).
					Msg("invalid HMAC")
				replyJSON(&reqID, w, message{"status": "error", "reason": "invalid_hmac"})
				return
			}
			next.ServeHTTP(w, req)
		})
	})
}

// The recombineReadCloser is used during payload submission requests to recombine the request message,
// already read inside the authorization middleware with the remaining request body and ensure that the
// body (io.ReadCloser) is eventually closed and does not leak
type recombineReadCloser struct {
	combined io.Reader
	original io.ReadCloser
}

func newRecombineReadCloser(head []byte, tail io.ReadCloser) *recombineReadCloser {
	return &recombineReadCloser{io.MultiReader(bytes.NewReader(head), tail), tail}
}

func (r recombineReadCloser) Read(p []byte) (int, error) {
	return r.combined.Read(p)
}

func (r recombineReadCloser) Close() error {
	return r.original.Close()
}
