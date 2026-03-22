.PHONY: build clean init

KEYDIR  := .tmp
PRIVKEY := $(KEYDIR)/packer_key
PUBKEY  := $(KEYDIR)/packer_key.pub

$(KEYDIR):
	mkdir -p $(KEYDIR)

$(PRIVKEY): | $(KEYDIR)
	ssh-keygen -t ed25519 -f $(PRIVKEY) -N "" -C "packer-build" -q

init:
	packer init devbox.pkr.hcl

build: $(PRIVKEY)
	packer build \
	  -var "ssh_public_key=$$(cat $(PUBKEY))" \
	  -var "ssh_private_key_file=$(PRIVKEY)" \
	  devbox.pkr.hcl

clean:
	rm -rf $(KEYDIR) output
