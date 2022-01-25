curve = secp384r1
days = 7300
hash = sha384

masters = $(shell grep ^M nodes | cut -d' ' -f2)
workers = $(shell grep ^W nodes | cut -d' ' -f2)
nodes = $(masters) $(workers)

out = out

SHELL = /bin/bash

all: ca commons etcd

.PHONY : clean
clean:
	rm -rf $(out)
	mkdir -p $(out)

%.key:
	openssl ecparam -genkey -name $(curve) -out $@

.PHONY : ca
ca: $(out)/ca.key $(out)/ca.crt

$(out)/ca.crt: $(out)/ca.key
	openssl req -new -x509 -days $(days) -$(hash) \
		-config openssl.cnf -extensions ca_ext \
		-key $< -out $@ \
		-subj '/CN=kubernetes'

%.crt: %.csr
	openssl x509 -req -CA $(out)/ca.crt -CAkey $(out)/ca.key -CAcreateserial -days $(days) -$(hash) \
		-extfile openssl.cnf -extensions client_ext \
		-in $< -out $@

.PHONY : commons
commons: \
	$(out)/apiserver.crt \
	$(out)/apiserver-kubelet-client.crt \
	$(out)/controller-manager.crt \
	$(out)/scheduler.crt \
	$(out)/admin.crt \
	kubelet \
	front-proxy \
	sa

$(out)/apiserver.csr: $(out)/apiserver.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=kube-apiserver"

$(out)/apiserver.crt: $(out)/apiserver.csr
	SAN="$$($(SHELL) helper API_SAN)" \
	openssl x509 -req -CA $(out)/ca.crt -CAkey $(out)/ca.key -CAcreateserial -days $(days) -$(hash) \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(out)/apiserver-kubelet-client.csr: $(out)/apiserver-kubelet-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kube-apiserver-kubelet-client"

$(out)/controller-manager.csr: $(out)/controller-manager.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=system:kube-controller-manager"

$(out)/scheduler.csr: $(out)/scheduler.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=system:kube-scheduler"

$(out)/admin.csr: $(out)/admin.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kubernetes-admin"

.PHONY : kubelet
kubelet: $(nodes:%=$(out)/%-kubelet-server.crt) $(nodes:%=$(out)/%-kubelet-client.crt)
$(nodes:%=$(out)/%-kubelet-server.csr): $(out)/%-kubelet-server.csr: $(out)/%-kubelet-server.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:nodes/CN=system:node:$*"

$(nodes:%=$(out)/%-kubelet-server.crt): $(out)/%-kubelet-server.crt: $(out)/%-kubelet-server.csr
	SAN="$$($(SHELL) helper NODE_SAN)" \
	openssl x509 -req -CA $(out)/ca.crt -CAkey $(out)/ca.key -CAcreateserial -days $(days) -$(hash) \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(nodes:%=$(out)/%-kubelet-client.csr): $(out)/%-kubelet-client.csr: $(out)/%-kubelet-server.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:nodes/CN=system:node:$*"

.PHONY : sa
sa : $(out)/sa.key $(out)/sa.pub

$(out)/sa.pub: $(out)/sa.key
	openssl ec -pubout -in $< -out $@

.PHONY : front-proxy
front-proxy: $(out)/front-proxy-ca.crt $(out)/front-proxy-client.crt

$(out)/front-proxy-ca.crt: $(out)/front-proxy-ca.key
	openssl req -new -x509 -days $(days) -$(hash) \
		-config openssl.cnf -extensions ca_ext \
		-key $< -out $@ \
		-subj '/CN=front-proxy-ca'

$(out)/front-proxy-client.csr: $(out)/front-proxy-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=front-proxy-client"

$(out)/front-proxy-client.crt: $(out)/front-proxy-client.csr $(out)/front-proxy-ca.crt
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/front-proxy-ca.crt -CAkey $(out)/front-proxy-ca.key \
		-extfile openssl.cnf -extensions client_ext \
		-in $< -out $@

.PHONY : etcd
etcd: $(out)/etcd-ca.crt \
	$(masters:%=$(out)/%-etcd-server.crt) \
	$(masters:%=$(out)/%-etcd-peer.crt) \
	$(out)/etcd-healthcheck-client.crt \
	$(out)/apiserver-etcd-client-client.crt

$(out)/etcd-ca.crt: $(out)/etcd-ca.key
	openssl req -new -x509 -days $(days) -$(hash) \
		-config openssl.cnf -extensions ca_ext \
		-key $< -out $@ \
		-subj '/CN=kubernetes'

$(masters:%=$(out)/%-etcd-server.csr): $(out)/%-etcd-server.csr: $(out)/%-etcd-server.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=$*"

$(masters:%=$(out)/%-etcd-server.crt): $(out)/%-etcd-server.crt: $(out)/%-etcd-server.csr
	SAN="$$($(SHELL) helper NODE_SAN $*)" \
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(masters:%=$(out)/%-etcd-peer.csr): $(out)/%-etcd-peer.csr: $(out)/%-etcd-peer.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=kube-etcd-peer"

$(masters:%=$(out)/%-etcd-peer.crt): $(out)/%-etcd-peer.crt: $(out)/%-etcd-peer.csr
	SAN="$$($(SHELL) helper NODE_SAN $*)" \
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(out)/etcd-healthcheck-client.csr: $(out)/etcd-healthcheck-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kube-etcd-healthcheck-client"

$(out)/etcd-healthcheck-client.crt: $(out)/etcd-healthcheck-client.csr
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions client_ext \
		-in $< -out $@

$(out)/apiserver-etcd-client-client.csr: $(out)/apiserver-etcd-client-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kube-apiserver-etcd-client"

$(out)/apiserver-etcd-client-client.crt: $(out)/apiserver-etcd-client-client.csr
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions client_ext \
		-in $< -out $@

.PHONY : collect
collect:
	mkdir -p etc

install: collect
