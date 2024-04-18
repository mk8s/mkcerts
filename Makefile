curve = secp384r1
days = 7305
hash = sha384

masters = $(shell grep ^M nodes | cut -d' ' -f2)
workers = $(shell grep ^W nodes | cut -d' ' -f2)
apiaddr = $(shell sort nodes | grep '^\(F\|M\) ' | head -n1 | cut -d' ' -f3)
nodes = $(masters) $(workers)
myhost = $(shell hostname)
myhost_cp = $(findstring $(myhost), $(masters))

out = out

SHELL = /bin/bash

all: ca commons etcd

.PHONY : clean
clean:
	rm -rf $(out)
	mkdir -p $(out)

%.key:
	openssl ecparam -genkey -name $(curve) | openssl ec -out $@

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
	$(out)/apiserver-kubelet-client.crt \
	$(out)/controller-manager.conf \
	$(out)/scheduler.conf \
	$(out)/admin.conf \
	kubelet \
	front-proxy \
	sa

$(out)/apiserver-kubelet-client.csr: $(out)/apiserver-kubelet-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kube-apiserver-kubelet-client"

$(out)/controller-manager.csr: $(out)/controller-manager.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=system:kube-controller-manager"

$(out)/controller-manager.conf: $(out)/controller-manager.crt
	kubectl --kubeconfig $@ config set-cluster kubernetes \
		--server https://$(apiaddr):6443 \
		--certificate-authority $(out)/ca.crt \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-credentials system:kube-controller-manager \
		--client-certificate $< \
		--client-key $(out)/controller-manager.key \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-context \
		system:kube-controller-manager@kubernetes \
		--cluster kubernetes \
		--user system:kube-controller-manager
	kubectl --kubeconfig $@ config use-context system:kube-controller-manager@kubernetes

$(out)/scheduler.csr: $(out)/scheduler.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=system:kube-scheduler"

$(out)/scheduler.conf: $(out)/scheduler.crt
	kubectl --kubeconfig $@ config set-cluster kubernetes \
		--server https://$(apiaddr):6443 \
		--certificate-authority $(out)/ca.crt \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-credentials system:kube-scheduler \
		--client-certificate $< \
		--client-key $(out)/scheduler.key \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-context \
		system:kube-scheduler@kubernetes \
		--cluster kubernetes \
		--user system:kube-scheduler
	kubectl --kubeconfig $@ config use-context system:kube-scheduler@kubernetes

$(out)/admin.csr: $(out)/admin.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kubernetes-admin"

$(out)/admin.conf: $(out)/admin.crt
	kubectl --kubeconfig $@ config set-cluster kubernetes \
		--server https://$(apiaddr):6443 \
		--certificate-authority $(out)/ca.crt \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-credentials kubernetes-admin \
		--client-certificate $< \
		--client-key $(out)/admin.key \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-context \
		kubernetes-admin@kubernetes \
		--cluster kubernetes \
		--user kubernetes-admin
	kubectl --kubeconfig $@ config use-context kubernetes-admin@kubernetes

.PHONY : kubelet
kubelet: $(nodes:%=$(out)/%-kubelet.conf)
$(nodes:%=$(out)/%-kubelet.csr): $(out)/%-kubelet.csr: $(out)/%-kubelet.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:nodes/CN=system:node:$*"

$(nodes:%=$(out)/%-kubelet.crt): $(out)/%-kubelet.crt: $(out)/%-kubelet.csr
	SAN="$$($(SHELL) helper NODE_SAN)" \
	openssl x509 -req -CA $(out)/ca.crt -CAkey $(out)/ca.key -CAcreateserial -days $(days) -$(hash) \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(nodes:%=$(out)/%-kubelet.conf): $(out)/%-kubelet.conf: $(out)/%-kubelet.crt
	kubectl --kubeconfig $@ config set-cluster kubernetes \
		--server https://$(apiaddr):6443 \
		--certificate-authority $(out)/ca.crt \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-credentials system:node:$* \
		--client-certificate $< \
		--client-key $(out)/$*-kubelet.key \
		--embed-certs=true
	kubectl --kubeconfig $@ config set-context \
		system:node:$*@kubernetes \
		--cluster kubernetes \
		--user system:node:$*
	kubectl --kubeconfig $@ config use-context system:node:$*@kubernetes

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
	$(masters:%=$(out)/%-apiserver.crt) \
	$(out)/apiserver-etcd-client.crt

$(out)/etcd-ca.crt: $(out)/etcd-ca.key
	openssl req -new -x509 -days $(days) -$(hash) \
		-config openssl.cnf -extensions ca_ext \
		-key $< -out $@ \
		-subj '/CN=kubernetes'

$(masters:%=$(out)/%-etcd-server.csr): $(out)/%-etcd-server.csr: $(out)/%-etcd-server.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=$*"

$(masters:%=$(out)/%-etcd-server.crt): $(out)/%-etcd-server.crt: $(out)/%-etcd-server.csr
	SAN="$$($(SHELL) helper NODE_SAN $*),IP:127.0.0.1" \
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(masters:%=$(out)/%-etcd-peer.csr): $(out)/%-etcd-peer.csr: $(out)/%-etcd-peer.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=kube-etcd-peer"

$(masters:%=$(out)/%-etcd-peer.crt): $(out)/%-etcd-peer.crt: $(out)/%-etcd-peer.csr
	SAN="$$($(SHELL) helper NODE_SAN $*),IP:127.0.0.1" \
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

$(masters:%=$(out)/%-apiserver.csr): $(out)/%-apiserver.csr: $(out)/%-apiserver.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/CN=kube-apiserver"

$(masters:%=$(out)/%-apiserver.crt): $(out)/%-apiserver.crt: $(out)/%-apiserver.csr
	SAN="$$($(SHELL) helper API_SAN $*)" \
	openssl x509 -req -CA $(out)/ca.crt -CAkey $(out)/ca.key -CAcreateserial -days $(days) -$(hash) \
		-extfile openssl.cnf -extensions server_ext \
		-in $< -out $@

$(out)/apiserver-etcd-client.csr: $(out)/apiserver-etcd-client.key
	openssl req -new -$(hash) -key $< -out $@ \
		-subj "/O=system:masters/CN=kube-apiserver-etcd-client"

$(out)/apiserver-etcd-client.crt: $(out)/apiserver-etcd-client.csr
	openssl x509 -req -CAcreateserial -days $(days) -$(hash) \
		-CA $(out)/etcd-ca.crt -CAkey $(out)/etcd-ca.key \
		-extfile openssl.cnf -extensions client_ext \
		-in $< -out $@

.PHONY : collect
collect:
	mkdir -p etc
	install -D -m 644 $(out)/ca.crt /etc/kubernetes/pki/ca.crt
	install -D -m 644 $(out)/etcd-ca.crt /etc/kubernetes/pki/etcd/ca.crt
ifeq ($(myhost_cp), $(myhost))
	install -D -m 644 $(out)/etcd-healthcheck-client.crt /etc/kubernetes/pki/etcd/healthcheck-client.crt
	install -D -m 600 $(out)/etcd-healthcheck-client.key /etc/kubernetes/pki/etcd/healthcheck-client.key
	install -D -m 644 $(out)/$(myhost)-etcd-peer.crt /etc/kubernetes/pki/etcd/peer.crt
	install -D -m 600 $(out)/$(myhost)-etcd-peer.key /etc/kubernetes/pki/etcd/peer.key
	install -D -m 644 $(out)/$(myhost)-etcd-server.crt /etc/kubernetes/pki/etcd/server.crt
	install -D -m 600 $(out)/$(myhost)-etcd-server.key /etc/kubernetes/pki/etcd/server.key
	install -D -m 644 $(out)/$(myhost)-apiserver.crt /etc/kubernetes/pki/apiserver.crt
	install -D -m 640 $(out)/$(myhost)-apiserver.key /etc/kubernetes/pki/apiserver.key
	install -D -m 644 $(out)/apiserver-etcd-client.crt /etc/kubernetes/pki/apiserver-etcd-client.crt
	install -D -m 600 $(out)/apiserver-etcd-client.key /etc/kubernetes/pki/apiserver-etcd-client.key
	install -D -m 644 $(out)/apiserver-kubelet-client.crt /etc/kubernetes/pki/apiserver-kubelet-client.crt
	install -D -m 600 $(out)/apiserver-kubelet-client.key /etc/kubernetes/pki/apiserver-kubelet-client.key
	install -D -m 644 $(out)/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
	install -D -m 644 $(out)/front-proxy-client.crt /etc/kubernetes/pki/front-proxy-client.crt
	install -D -m 600 $(out)/front-proxy-client.key /etc/kubernetes/pki/front-proxy-client.key
	install -D -m 644 $(out)/sa.pub /etc/kubernetes/pki/sa.pub
	install -D -m 600 $(out)/sa.key /etc/kubernetes/pki/sa.key
	install -D -m 600 $(out)/admin.conf /etc/kubernetes/admin.conf
	install -D -m 600 $(out)/controller-manager.conf /etc/kubernetes/controller-manager.conf
	install -D -m 600 $(out)/scheduler.conf /etc/kubernetes/scheduler.conf
endif
	install -D -m 600 $(out)/$(myhost)-kubelet.conf /etc/kubernetes/kubelet.conf
	install -D -m 644 $(out)/$(myhost)-kubelet.crt /var/lib/kubelet/pki/kubelet.crt
	install -D -m 600 $(out)/$(myhost)-kubelet.key /var/lib/kubelet/pki/kubelet.key

install: collect
