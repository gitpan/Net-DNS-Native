#include <pthread.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"
#include "bstree.h"

#if defined(WIN32) && !defined(UNDER_CE)
# include <io.h>
# define write _write
#endif

typedef struct {
	pthread_mutex_t mutex;
	pthread_attr_t thread_attrs;
	bstree* fd_map;
} Net_DNS_Native;

typedef struct {
	Net_DNS_Native *self;
	char *host;
	char *service;
	struct addrinfo *hints;
	int fd0;
} DNS_thread_arg;

typedef struct {
	int fd1;
	int error;
	struct addrinfo *hostinfo;
	int type;
	DNS_thread_arg *arg;
} DNS_result;

char *_copy_str(char *orig) {
	// workaround for http://www.perlmonks.org/?node_id=742205
	int len = strlen(orig) + 1;
	char *new = malloc(len*sizeof(char));
	memcpy(new, orig, len);
	return new;
}

void *_getaddrinfo(void *v_arg) {
	DNS_thread_arg *arg = (DNS_thread_arg *)v_arg;
	
	pthread_mutex_lock(&arg->self->mutex);
	DNS_result *res = bstree_get(arg->self->fd_map, arg->fd0);
	pthread_mutex_unlock(&arg->self->mutex);
	
	res->error = getaddrinfo(arg->host, arg->service, arg->hints, &res->hostinfo);
	
	res->arg = arg;
	write(res->fd1, "1", 1);
	
	return NULL;
}

MODULE = Net::DNS::Native	PACKAGE = Net::DNS::Native

PROTOTYPES: DISABLE

SV*
new(char* class)
	PREINIT:
		Net_DNS_Native *self;
	CODE:
		Newx(self, 1, Net_DNS_Native);
		pthread_attr_init(&self->thread_attrs);
		pthread_attr_setdetachstate(&self->thread_attrs, PTHREAD_CREATE_DETACHED);
		pthread_mutex_init(&self->mutex, NULL);
		self->fd_map = bstree_new();
		
		RETVAL = newSV(0);
		sv_setref_pv(RETVAL, class, (void *)self);
	OUTPUT:
		RETVAL

int
_getaddrinfo(Net_DNS_Native *self, char *host, char *service, SV* sv_hints, int type)
	INIT:
		int fd[2];
	CODE:
		if (socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC, fd) != 0)
			croak("socketpair(): %s", strerror(errno));
		
		struct addrinfo *hints = NULL;
		
		if (SvOK(sv_hints)) {
			// defined
			if (!SvROK(sv_hints) || SvTYPE(SvRV(sv_hints)) != SVt_PVHV) {
				// not reference or not a hash inside reference
				croak("hints should be reference to hash");
			}
			
			hints = malloc(sizeof(struct addrinfo));
			hints->ai_flags = 0;
			hints->ai_family = AF_UNSPEC;
			hints->ai_socktype = 0;
			hints->ai_protocol = 0;
			hints->ai_addrlen = 0;
			hints->ai_addr = NULL;
			hints->ai_canonname = NULL;
			hints->ai_next = NULL;
			
			HV* hv_hints = (HV*)SvRV(sv_hints);
			
			SV **flags_ptr = hv_fetch(hv_hints, "flags", 5, 0);
			if (flags_ptr != NULL) {
				hints->ai_flags = SvIV(*flags_ptr);
			}
			
			SV **family_ptr = hv_fetch(hv_hints, "family", 6, 0);
			if (family_ptr != NULL) {
				hints->ai_family = SvIV(*family_ptr);
			}
			
			SV **socktype_ptr = hv_fetch(hv_hints, "socktype", 8, 0);
			if (socktype_ptr != NULL) {
				hints->ai_socktype = SvIV(*socktype_ptr);
			}
			
			SV **protocol_ptr = hv_fetch(hv_hints, "protocol", 8, 0);
			if (protocol_ptr != NULL) {
				hints->ai_protocol = SvIV(*protocol_ptr);
			}
		}
		
		DNS_result *res = malloc(sizeof(DNS_result));
		res->fd1 = fd[1];
		res->error = 0;
		res->hostinfo = NULL;
		res->type = type;
		res->arg = NULL;
		bstree_put(self->fd_map, fd[0], res);
		
		DNS_thread_arg *arg = malloc(sizeof(DNS_thread_arg));
		arg->self = self;
		arg->host = strlen(host) ? _copy_str(host) : NULL;
		arg->service = strlen(service) ? _copy_str(service) : NULL;
		arg->hints = hints;
		arg->fd0 = fd[0];
		
		pthread_t tid;
		int rc = pthread_create(&tid, &self->thread_attrs, _getaddrinfo, (void *)arg);
		if (rc != 0) {
			if (arg->host)    free(arg->host);
			if (arg->service) free(arg->service);
			free(arg);
			free(res);
			if (hints) free(hints);
			bstree_del(self->fd_map, fd[0]);
			close(fd[0]);
			close(fd[1]);
			croak("pthread_create(): %s", strerror(rc));
		}
		
		RETVAL = fd[0];
	OUTPUT:
		RETVAL

void
_get_result(Net_DNS_Native *self, int fd)
	PPCODE:
		pthread_mutex_lock(&self->mutex);
		DNS_result *res = bstree_get(self->fd_map, fd);
		bstree_del(self->fd_map, fd);
		pthread_mutex_unlock(&self->mutex);
		
		if (res == NULL) croak("attempt to get result which doesn't exists");
		if (!res->arg) {
			pthread_mutex_lock(&self->mutex);
			bstree_put(self->fd_map, fd, res);
			pthread_mutex_unlock(&self->mutex);
			croak("attempt to get not ready result");
		}
		
		XPUSHs(sv_2mortal(newSViv(res->type)));
		SV *err = newSV(0);
		sv_setiv(err, (IV)res->error);
		sv_setpv(err, res->error ? gai_strerror(res->error) : "");
		SvIOK_on(err);
		XPUSHs(sv_2mortal(err));
		
		if (!res->error) {
			struct addrinfo *info;
			for (info = res->hostinfo; info != NULL; info = info->ai_next) {
				HV *hv_info = newHV();
				hv_store(hv_info, "family", 6, newSViv(info->ai_family), 0);
				hv_store(hv_info, "socktype", 8, newSViv(info->ai_socktype), 0);
				hv_store(hv_info, "protocol", 8, newSViv(info->ai_protocol), 0);
				hv_store(hv_info, "addr", 4, newSVpvn((char*)info->ai_addr, info->ai_addrlen), 0);
				hv_store(hv_info, "canonname", 9, info->ai_canonname ? newSVpv(info->ai_canonname, 0) : newSV(0), 0);
				XPUSHs(sv_2mortal(newRV_noinc((SV*)hv_info)));
			}
			
			freeaddrinfo(res->hostinfo);
		}
		
		close(fd);
		close(res->fd1);
		if (res->arg->hints)   free(res->arg->hints);
		if (res->arg->host)    free(res->arg->host);
		if (res->arg->service) free(res->arg->service);
		free(res->arg);
		free(res);

void
DESTROY(Net_DNS_Native *self)
	CODE:
		pthread_attr_destroy(&self->thread_attrs);
		pthread_mutex_destroy(&self->mutex);
		bstree_destroy(self->fd_map);
		Safefree(self);

void
pack_sockaddr_in6(int port, SV *sv_address)
	PPCODE:
		int len;
		char *address = SvPV(sv_address, len);
		if (len != 16)
			croak("address length is %d should be 16", len);
		
		struct sockaddr_in6 *addr = malloc(sizeof(struct sockaddr_in6));
		memcpy(addr->sin6_addr.s6_addr, address, 16);
		addr->sin6_family = AF_INET6;
		addr->sin6_port = port;
		
		XPUSHs(sv_2mortal(newSVpvn((char*) addr, sizeof(struct sockaddr_in6))));

void
unpack_sockaddr_in6(SV *sv_addr)
	PPCODE:
		int len;
		char *addr = SvPV(sv_addr, len);
		if (len != sizeof(struct sockaddr_in6))
			croak("address length is %d should be %d", len, sizeof(struct sockaddr_in6));
		
		struct sockaddr_in6 *struct_addr = (struct sockaddr_in6*) addr;
		XPUSHs(sv_2mortal(newSViv(struct_addr->sin6_port)));
		XPUSHs(sv_2mortal(newSVpvn(struct_addr->sin6_addr.s6_addr, 16)));
