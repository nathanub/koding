package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"koding/kites/common"
	"koding/kites/kloud/pkg/dnsclient"

	"github.com/koding/kite"
	"github.com/koding/logging"
	"github.com/koding/multiconfig"
	"github.com/koding/streamtunnel"
	"github.com/mitchellh/goamz/aws"
)

type registerResult struct {
	VirtualHost string
	Identifier  string
}

type tunnelServer struct {
	Port            int
	Debug           bool
	BaseVirtualHost string `required:"true"`

	// ServerAddr is public Address of the running server. Like an assigned Elastic IP
	ServerAddr string `required:"true"`

	HostedZone string
	AccessKey  string
	SecretKey  string

	// internal
	Log    logging.Logger
	Server *streamtunnel.Server
	Dns    *dnsclient.Route53
}

func main() {
	t := new(tunnelServer)
	m := multiconfig.New()
	m.MustLoad(t)
	m.MustValidate(t)

	auth := aws.Auth{
		AccessKey: t.AccessKey,
		SecretKey: t.SecretKey,
	}

	t.Dns = dnsclient.NewRoute53Client(t.HostedZone, auth)
	t.Server = streamtunnel.NewServer(&streamtunnel.ServerConfig{
		Debug: t.Debug,
	})
	t.Log = common.NewLogger("tunnelkite", t.Debug)

	k := kite.New("tunnelserver", "0.0.1")
	k.Config.DisableAuthentication = true
	k.Config.Port = t.Port

	k.HandleFunc("register", t.Register)
	k.HandleHTTP("/{rest:.*}", t.Server)

	k.Run()
}

func (t *tunnelServer) Register(r *kite.Request) (interface{}, error) {
	virtualHost := fmt.Sprintf("%s.%s", r.Username, t.BaseVirtualHost)
	identifier := randomID(32)

	domain := r.Username + "." + t.Dns.HostedZone()

	t.Log.Debug("Adding domain '%s' with to IP Address '%s'", domain, t.ServerAddr)
	if err := t.Dns.Upsert(domain, t.ServerAddr); err != nil {
		return nil, err
	}

	t.Log.Debug("Adding host '%s' with identifer '%s'", virtualHost, identifier)
	t.Server.AddHost(virtualHost, identifier)

	// cleanup domain and delete in memory virtualhost
	t.Server.OnDisconnect(identifier, func() error {
		t.Log.Debug("Deleting host '%s' and domain '%s'", virtualHost, domain)
		t.Server.DeleteHost(virtualHost)
		return t.Dns.Delete(domain)
	})

	return registerResult{
		VirtualHost: virtualHost,
		Identifier:  identifier,
	}, nil
}

// randomID generates a random string of the given length
func randomID(length int) string {
	r := make([]byte, length*6/8)
	rand.Read(r)
	return base64.URLEncoding.EncodeToString(r)
}
