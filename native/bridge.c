#include "abi.h"
#include "o66_native.h"
#define MAGIC 0x36424c45u
#define VERSION 0x00010004u
#define COUNT 16u
#define LIMIT 514u
/* Shared layout is an explicit wire ABI; all mutable storage is owned Umem. */
typedef struct { uint32_t type,status,a,b,length,generation; uint8_t data[520]; } Event;
typedef struct { volatile uint32_t sequence; Event event; } Notification;
typedef struct {
 o66_mailbox box;
 uint32_t magic,version,image_size,image_crc;
 volatile uint32_t status,error,request,ack,command,a,b,length;
 uint8_t data[516];
 volatile uint32_t heartbeat,closing,connected,scanning,head,tail,dropped,generation,ack_generation;
 volatile uint32_t ack_error;
 volatile uint32_t notify_head,notify_dropped,notify_lock;
 volatile uint32_t ui_suspended;
 uint32_t control_seq,control_handle,control_count,control_pos;
 volatile uint32_t control_waiting;
 uint32_t control_inflight_seq,control_inflight_handle;
 volatile uint32_t control_done,control_result;
 uint32_t control_ticks,control_armed,control_shutdown,control_stop;
 uint8_t control_frames[36],stop_frames[36];
 uint8_t reserved[248];
 Event events[COUNT];
 void *instance,*client,*scan;
 uint32_t thread, scan_cb[4], gatt_cb[13];
 volatile uint32_t event_lock;
 struct { uint8_t address[6]; uint16_t used; uint32_t hash; } seen[24];
 Notification notifications[COUNT];
} State;
_Static_assert(offsetof(State,heartbeat)==596,"heartbeat ABI");
_Static_assert(offsetof(State,events)==1024,"event ABI");
_Static_assert(sizeof(Event)==544,"event size");
_Static_assert(offsetof(State,notify_head)==636,"notification counters ABI");
_Static_assert(offsetof(State,ui_suspended)==648,"UI suspend ABI");
_Static_assert(offsetof(State,control_frames)==704,"control batch ABI");
_Static_assert(offsetof(State,notifications)==10104,"notification buffer ABI");
_Static_assert(sizeof(Notification)==548,"notification slot ABI");
_Static_assert(sizeof(State)==18872,"state size ABI");
extern State *ble_state(void);
static void copy(void *d,const void *s,uint32_t n) { uint8_t *a=d; const uint8_t *b=s; while(n--) *a++=*b++; }
static void zero(void *d,uint32_t n) { uint8_t *a=d;while(n--) *a++=0; }
void __aeabi_memclr4(void *d,uint32_t n) { zero(d,n); }
static uint32_t crc(const void *p,uint32_t n) {
 const uint8_t *b=p;uint32_t c=~0u;while(n--) {c^=*b++;for(int i=0;i<8;i++)c=(c>>1)^(0xedb88320u&-(c&1));}return ~c;
}
static uint32_t load(volatile uint32_t *p) { return __atomic_load_n(p,__ATOMIC_ACQUIRE); }
static void save(volatile uint32_t *p,uint32_t v) { __atomic_store_n(p,v,__ATOMIC_RELEASE); }
/* Callback producers never wait for a lock held by a preempted lower-priority task. */
static void event(uint32_t type,uint32_t status,uint32_t a,uint32_t b,const void *data,uint32_t n) {
 State *s=ble_state();
 if(__atomic_exchange_n(&s->event_lock,1,__ATOMIC_ACQUIRE)) {__atomic_fetch_add(&s->dropped,1,__ATOMIC_RELAXED);return;}
 uint32_t h=load(&s->head),t=load(&s->tail);
 if(h-t>=COUNT || n>LIMIT) __atomic_fetch_add(&s->dropped,1,__ATOMIC_RELAXED);
 else {
  Event *e=&s->events[h%COUNT];e->type=type;e->status=status;e->a=a;e->b=b;e->length=n;e->generation=load(&s->generation);
  if(n)copy(e->data,data,n);save(&s->head,h+1);
 }
 save(&s->event_lock,0);
}
static void on_scan(void *cookie,const uint8_t *p) {
 (void)cookie;State *s=ble_state();if(load(&s->scanning)!=2 || load(&s->closing))return;
 /* Address[6], address type, signed RSSI, advertising type, PHY, data length, AD bytes. */
 uint32_t n=11u+p[10],hash=crc(p+8,n-8);int slot=-1;
 for(int i=0;i<24;i++) {
  if(!s->seen[i].used) {if(slot<0)slot=i;continue;}
  int same=1;for(int j=0;j<6;j++)if(s->seen[i].address[j]!=p[j])same=0;
  if(same) {if(s->seen[i].hash==hash)return;slot=i;break;}
 }
 if(slot<0)return;
 if(slot>=0) {copy(s->seen[slot].address,p,6);s->seen[slot].hash=hash;s->seen[slot].used=1;}
 event(1,0,0,0,p,n);
}
static void on_scan_started(void *cookie,uint8_t status) {
 State *s=ble_state();(void)cookie;save(&s->scanning,status?0:2);event(2,status,0,0,0,0);
}
static void on_scan_stopped(void *cookie) {
 State *s=ble_state();(void)cookie;save(&s->scanning,0);event(3,0,0,0,0,0);
 /* Firmware frees this cookie AFTER this callback (0x0c4c8388). */
}
static void on_connected(void *c,const uint8_t *address) {
 (void)c;save(&ble_state()->connected,2);event(4,0,0,0,address,6);
}
static void on_disconnected(void *c,const uint8_t *address) {
 (void)c;save(&ble_state()->connected,0);event(5,0,0,0,address,6);
}
static void on_discovered(void *c,uint8_t status,const uint8_t *uuid,uint16_t first,uint16_t last) {
 (void)c;event(6,status,first,last,uuid,uuid?20:0);
}
static void on_read(void *c,uint8_t status,uint16_t handle,const void *data,uint16_t length) {
 (void)c;event(7,status,handle,0,data,length);
}
static void on_write(void *c,uint8_t status,uint16_t handle) {
 (void)c;State *s=ble_state();event(8,status,handle,0,0,0);
 if(load(&s->control_waiting) && handle==s->control_inflight_handle) {
  save(&s->control_result,status);save(&s->control_done,1);
 }
}
static void on_subscribed(void *c,uint8_t status,uint16_t handle,uint8_t enabled) { (void)c;event(9,status,handle,enabled,0,0); }
static void on_notify(void *c,uint16_t handle,const void *data,uint16_t length) {
 (void)c;State *s=ble_state();
 /* Notifications are a bounded recent-history stream, not control completions.
    Never contend with the control queue or overwrite a slot without a sequence
    change: Lua may be reading this buffer across several shell invocations. */
 if(length>LIMIT) {__atomic_fetch_add(&s->notify_dropped,1,__ATOMIC_RELAXED);return;}
 if(__atomic_exchange_n(&s->notify_lock,1,__ATOMIC_ACQUIRE)) {
  __atomic_fetch_add(&s->notify_dropped,1,__ATOMIC_RELAXED);return;
 }
 uint32_t h=load(&s->notify_head),seq=(h+1)*2;
 Notification *slot=&s->notifications[h%COUNT];
 /* Full barrier after marking busy, before changing any payload word. */
 __atomic_store_n(&slot->sequence,seq|1,__ATOMIC_SEQ_CST);
 Event *e=&slot->event;
 e->type=10;e->status=0;e->a=handle;e->b=0;e->length=length;e->generation=load(&s->generation);
 if(length)copy(e->data,data,length);
 save(&slot->sequence,seq);save(&s->notify_head,h+1);save(&s->notify_lock,0);
}
static int stop_scan(State *s) {
 if(load(&s->scanning)!=2)return 0;
 save(&s->scanning,3);int rc=scan_stop(s->instance,s->scan);
 if(rc)save(&s->scanning,2);return rc;
}
static int close_link(State *s) {
 int rc=stop_scan(s);uint32_t c=load(&s->connected);
 if(c==1 || c==2) {save(&s->connected,3);int r=client_disconnect(s->client);if(r)save(&s->connected,c);if(!rc)rc=r;}
 return rc;
}
static void control_finish(State *s,int rc) {
 event(12,(uint32_t)rc,s->control_handle,s->control_seq,0,0);
 if((!rc && s->control_stop) || s->control_shutdown)s->control_armed=0;
 if(rc)save(&s->error,(uint32_t)rc);
 s->control_count=0;
}
static void control_begin(State *s,uint32_t seq,uint32_t handle,const uint8_t *frames,uint32_t count,uint32_t stop) {
 if(s->control_count)event(12,(uint32_t)-125,s->control_handle,s->control_seq,0,0);
 s->control_seq=seq;s->control_handle=handle;s->control_pos=0;s->control_count=count;s->control_stop=stop;
 copy(s->control_frames,frames,count*12);
 /* An earlier write may still be on air. Its callback is consumed before the
    replacement starts; its sequence cannot complete the replacement batch. */
}
static void control_tick(State *s) {
 if(load(&s->connected)!=2) {
  if(s->control_count)control_finish(s,-107);
  save(&s->control_waiting,0);save(&s->control_done,0);s->control_armed=0;s->control_shutdown=0;return;
 }
 if(load(&s->control_waiting)) {
  if(!load(&s->control_done)) {
   if(++s->control_ticks<150)return;
   control_finish(s,-110);s->control_armed=0;save(&s->closing,1);
   save(&s->control_waiting,0);return;
  }
  int rc=(int)load(&s->control_result);
  save(&s->control_done,0);save(&s->control_waiting,0);
  if(s->control_inflight_seq==s->control_seq && s->control_count) {
   if(rc) {control_finish(s,rc);save(&s->closing,1);return;}
   ++s->control_pos;
  }
 }
 if(!s->control_count)return;
 if(s->control_pos==s->control_count) {control_finish(s,0);return;}
 s->control_ticks=0;s->control_inflight_seq=s->control_seq;s->control_inflight_handle=s->control_handle;
 save(&s->control_done,0);save(&s->control_waiting,1);
 int rc=write_request(s->client,(uint16_t)s->control_handle,s->control_frames+s->control_pos*12,12);
 if(rc) {save(&s->control_result,(uint32_t)rc);save(&s->control_done,1);}
}
static int command(State *s,uint32_t op) {
 if(op==1) { /* Attach only after the previous link and scan have finished. */
  if(load(&s->connected)||load(&s->scanning))return -16;
  save(&s->closing,0);__atomic_fetch_add(&s->generation,1,__ATOMIC_RELEASE);return 0;
 }
 if(op==10) {save(&s->closing,1);return s->control_armed?0:close_link(s);}
 if(load(&s->closing))return -125;
 if(op==2) {
  if(load(&s->scanning)||load(&s->connected))return -16;
  /* mode=1, legacy=true, active=true, PHY selector=0. Filter disabled. */
  uint8_t params[8]={1,0,0,0,1,1,0,0},filter[16]={0};
  zero(s->seen,sizeof(s->seen));save(&s->scanning,1);
  void *p=scan_start(s->instance,params,filter,s->scan_cb);
  if(!p) {save(&s->scanning,0);return -5;}
  s->scan=p;return 0;
 }
 if(op==3)return stop_scan(s);
 if(op==4) {
  if(load(&s->scanning)||load(&s->connected)||s->length!=6)return -16;
  save(&s->connected,1);int rc=client_connect(s->client,s->data);
  if(rc)save(&s->connected,0);return rc;
 }
 if(load(&s->connected)!=2)return -107;
 if(op==5)return discover(s->client,0);
 if(op==6) {uint8_t attr[32]={0};int rc=get_attribute(s->client,(uint16_t)s->a,attr);event(11,rc,s->a,0,attr,32);return rc;}
 if(op==7)return read_request(s->client,(uint16_t)s->a);
 if(op==8) {if(s->control_count || load(&s->control_waiting))return -16;if(!s->length || s->length>LIMIT)return -22;return write_request(s->client,(uint16_t)s->a,s->data,(uint16_t)s->length);}
 if(op==9) {if(s->b>1)return -22;return subscribe(s->client,(uint16_t)s->a,(uint16_t)s->b);}
 if(op==11 || op==12) {
  if(!s->a || s->length!=(op==11?60u:36u))return -22;
  copy(s->stop_frames,s->data+(op==11?24:0),36);
  s->control_armed=1;
  control_begin(s,load(&s->request),s->a,s->data,op==11?2:3,op==12);return 0;
 }
 return -22;
}
static int worker(int argc,char **argv) {
 (void)argc;(void)argv;State *s=ble_state();
 s->scan_cb[0]=16;s->scan_cb[1]=(uintptr_t)on_scan;s->scan_cb[2]=(uintptr_t)on_scan_started;s->scan_cb[3]=(uintptr_t)on_scan_stopped;
 s->gatt_cb[0]=52;s->gatt_cb[1]=(uintptr_t)on_connected;s->gatt_cb[2]=(uintptr_t)on_disconnected;
 s->gatt_cb[3]=(uintptr_t)on_discovered;s->gatt_cb[4]=(uintptr_t)on_read;s->gatt_cb[5]=(uintptr_t)on_write;
 s->gatt_cb[6]=(uintptr_t)on_subscribed;s->gatt_cb[7]=(uintptr_t)on_notify;
 s->instance=instance_create();
 int rc=s->instance?client_create(s->instance,&s->client,s->gatt_cb):-5;
 if(rc) {save(&s->error,(uint32_t)rc);save(&s->status,2);return 0;}
 save(&s->status,1);
 uint32_t beat=load(&s->heartbeat),silent=0,scan_ticks=0,connect_ticks=0;
 for(;;) {
  uint32_t background=load(&s->ui_suspended);
  uint32_t now=load(&s->heartbeat);
  if(background || now!=beat){beat=now;silent=0;}else if(silent<50)++silent;
  if(silent>=50)save(&s->closing,1);
  if(load(&s->closing)) {
   if(load(&s->connected)==2 && s->control_armed) {
    if(!s->control_shutdown) {s->control_shutdown=1;control_begin(s,0,s->control_handle,s->stop_frames,3,1);}
   }else {int r=close_link(s);if(r)save(&s->error,(uint32_t)r);}
  }
  uint32_t req=load(&s->request);
  if(req!=load(&s->ack)) {
   int r=command(s,load(&s->command));save(&s->ack_error,(uint32_t)r);
   save(&s->ack_generation,load(&s->generation));save(&s->ack,req);
  }
  if(load(&s->scanning)==2) {if(background || ++scan_ticks>=100)stop_scan(s);}else scan_ticks=0;
  if(load(&s->connected)==1) {if(++connect_ticks>=150)save(&s->closing,1);}else connect_ticks=0;
  control_tick(s);
  /* BLE socket callbacks have their own thread. An established sleeping link
     needs no Lua heartbeat and no 10 Hz management polling. Keep fast polling
     during scan/connection teardown and pending commands. */
  uint32_t idle=background && !load(&s->closing) && !load(&s->scanning) &&
                load(&s->connected)!=1 && load(&s->connected)!=3 &&
                load(&s->request)==load(&s->ack) && !s->control_count && !load(&s->control_waiting);
  delay_us(idle?1000000:100000);
 }
}
int o66_payload(volatile o66_mailbox *m) {
 /* This bootstrap is synchronous; only a copied Umem image can outlive it. */
 uint32_t n=m->input;if(n<128 || n>32768 || (n&3))return -22;
 uint8_t *p=zalloc(n+sizeof(State));if(!p)return -12;
 uintptr_t addr=(uintptr_t)p;
 if((addr&7)||addr<=0x3c337078u || addr+n+sizeof(State)>0x3cfefff8u) {release(p);return -14;}
 const uint8_t *source=(const uint8_t *)m+32;
 copy(p,source,n);State *s=(State *)(p+n);
 s->magic=MAGIC;s->version=VERSION;s->image_size=n;
 *(uint32_t *)(p+4)=0;s->image_crc=crc(p,n);*(uint32_t *)(p+4)=(uintptr_t)s;
 /* ble_state() in the copied image now resolves to persistent state. */
 clean_d();barrier();invalidate_i();barrier();
 uintptr_t fn=(uintptr_t)worker;
 uintptr_t source_code=(uintptr_t)source-0x20000000u;
 int (*entry)(int,char **)=(int (*)(int,char **))(fn-source_code+addr-0x20000000u);
 /* Independent NuttX task, following system() nxposix_spawn (not a pthread
    in the short-lived NSH task group). attr size/layout verified in firmware. */
 uint32_t attr[5]={0};int rc=spawn_attr_init(attr);
 if(rc) {release(p);return -rc;}
 ((uint8_t *)attr)[0]=4;((uint8_t *)attr)[1]=100;attr[3]=8192;
 char *args[1]={0};
 rc=task_spawn("o66_ble",entry,0,attr,args,0);
 if(rc<0) {release(p);return rc;}
 s->thread=(uint32_t)rc;
 m->output=(uintptr_t)s;return 0;
}
