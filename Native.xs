#include <pthread.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"
#include "bstree.h"

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
} DNS_result;

void *_getaddrinfo(void *v_arg) {
	DNS_thread_arg *arg = (DNS_thread_arg *)v_arg;
	
	pthread_mutex_lock(&arg->self->mutex);
	DNS_result *res = bstree_get(arg->self->fd_map, arg->fd0);
	pthread_mutex_unlock(&arg->self->mutex);
	
	res->error = getaddrinfo(arg->host, arg->service, arg->hints, &res->hostinfo);
	if (arg->hints)   free(arg->hints);
	if (arg->host)    free(arg->host);
	if (arg->service) free(arg->service);
	free(arg);
	
	write(res->fd1, "1", 1);
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
		bstree_put(self->fd_map, fd[0], res);
		
		DNS_thread_arg *arg = malloc(sizeof(DNS_thread_arg));
		arg->self = self;
		arg->host = strlen(host) ? strdup(host) : NULL;
		arg->service = strlen(service) ? strdup(service) : NULL;
		arg->hints = hints;
		arg->fd0 = fd[0];
		
		pthread_t tid;
		int rc = pthread_create(&tid, &self->thread_attrs, _getaddrinfo, (void *)arg);
		if (rc != 0) {
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
		free(res);

void
DESTROY(Net_DNS_Native *self)
	CODE:
		pthread_attr_destroy(&self->thread_attrs);
		pthread_mutex_destroy(&self->mutex);
		bstree_destroy(self->fd_map);
		Safefree(self);
