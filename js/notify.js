/* UniGuard · independent pending state. Never waits for Repo's form refresh gate. */
const UG_NOTIFY = (function () {
  const esc = UG_UTIL.esc, T = k => UG_I18N.t(k);
  const DEFAULTS = { sos_ack_timeout_s:60, sos_onscene_timeout_min:10, arrival_radius_m:100,
    signal_amber_s:60, signal_lost_s:180, repush_interval_s:60, sms_after_s:120, eta_speed_kmh:30, super_admin_sos_alarm:'backstop' };
  let revision = 0, hasConfirmed = false;
  let profile = null, channel = null, epoch = 0, poll = null, clock = null, fetching = false, again = false;
  let pendingSos = [], pendingAck = [], pendingDispatch = [], minimized = false, error = '', pushOn = false, offerCitizen = false;
  let pendingOpen = null;
  let enrollmentDismissed = false;
  let devices = [], filter = 'all', typeFilter = '', expanded = null, overlaySignature = '';
  const listeners = new Set(), retry = new Map(), busy = new Set(), urgentSeen = new Set();
  const responder = () => profile && ['lgu_ldrrmc','barangay_official','dispatch_team'].includes(profile.role);
  const superAdmin = () => !!(profile && profile.role === 'lgu_ldrrmc' && profile.is_super_admin);
  const staffSos = () => profile && ['lgu_ldrrmc','barangay_official'].includes(profile.role);
  const settings = () => Object.assign({}, DEFAULTS, UG.DATA.alertSettings || {});
  const app = () => window.UG_APP;
  function host(id) { let el = document.getElementById(id); if (!el) { el = document.createElement('div'); el.id = id; document.body.appendChild(el); } return el; }
  function setHTML(el, html) {
    // Sound unlock can repaint during pointerdown; preserve unchanged controls until click.
    if (el.__ugNotifyHTML !== html || (html && !el.firstChild)) { el.innerHTML=html; el.__ugNotifyHTML=html; }
  }
  const button = (action, id, label) => '<button class="ug-btn ug-btn--signal" data-ug-notify="'+action+'" data-id="'+esc(id || '')+'"'+(busy.has(action+':'+id)?' disabled':'')+'>'+esc(T(label))+'</button>';
  const time = value => value ? new Date(value).toLocaleTimeString(UG_I18N.isFil() ? 'fil-PH' : 'en-PH', { timeZone:'Asia/Manila',hour12:false }) : '—';
  function cachePending(){if(!profile)return;UG_NOTIF_STORE.pendingSnapshot(profile.id,{scope:[profile.role,profile.barangay_id,profile.dispatch_unit_id,profile.is_super_admin].join('|'),pendingSos,pendingAck,pendingDispatch}).catch(()=>{});}
  function sync() {
    if (!profile) return;
    const sirenSos = staffSos() && (pendingSos.length > 0 && (!superAdmin() || settings().super_admin_sos_alarm === 'every') || pendingAck.some(n => n.type === 'sos_escalation'));
    if (sirenSos) UG_ALARM.loop('sos','sos'); else UG_ALARM.stop('sos');
    if (profile.role === 'dispatch_team' && pendingDispatch.length) UG_ALARM.loop('dispatch','dispatch'); else UG_ALARM.stop('dispatch');
    pendingAck.forEach(n => {
      if (n.priority === 'urgent' && !urgentSeen.has(n.id)) {
        urgentSeen.add(n.id);
        if (responder() && !(superAdmin() && n.type === 'sos')) UG_ALARM.play(n.type === 'change_request' ? 'admin' : 'attention');
      }
    });
    paint(); listeners.forEach(fn => { try { fn(); } catch (e) {} });
  }
  function paint() {
    if (!profile) return;
    const count = pendingCount(), banner = host('ug-notify-banner');
    const needsSound = responder() && UG_ALARM.needsUnlock();
    banner.className = 'ug-notify-banner';
    const bannerHTML = (count ? '<button data-ug-notify="expand">'+(pendingSos.length?esc(T('notify.sosWaiting'))+' '+pendingSos.length+' · ':'')+esc(T('notify.itemsWaiting'))+' '+count+' · '+esc(T('notify.open'))+'</button>' : '') +
      (responder() ? '<button data-ug-notify="unlock">'+UG.icon('bell',16)+' '+esc(T('notify.enableSound'))+'</button>' : '') +
      (responder() && !pushOn ? '<button data-ug-notify="enroll">'+esc(T('notify.alertsOff'))+'</button>' : '');
    setHTML(banner,bannerHTML);
    const unlock = banner.querySelector('[data-ug-notify="unlock"]'); if (unlock) unlock.hidden = !needsSound;
    banner.hidden = !(count || needsSound || (responder() && !pushOn));
    document.body.classList.toggle('ug-has-notify-banner',!banner.hidden);
    document.querySelectorAll('[data-ug-action-count]').forEach(el => { el.textContent = String(count); el.hidden = count === 0; });
    const overlay = host('ug-notify-overlay');
    const visibleSos = staffSos() ? pendingSos : [];
    const signature = visibleSos.map(s=>s.id).concat(pendingDispatch.map(d=>d.id)).sort().join('|');
    if (signature !== overlaySignature && signature.split('|').some(id => id && !overlaySignature.split('|').includes(id))) {
      if (!superAdmin() || settings().super_admin_sos_alarm === 'every' || pendingAck.some(n=>n.type==='sos_escalation')) minimized = false;
    }
    overlaySignature = signature;
    const rows = visibleSos.map(s => '<article class="ug-notify-card"><h2>'+esc(UG_SOS.kindLabel(s.kind))+' · '+esc(s.profile_name)+'</h2>' +
      '<p>'+esc(s.barangay)+' · '+esc(time(s.created_at))+'</p>'+ (s.profile_phone ? '<a href="tel:'+esc(String(s.profile_phone).replace(/[^+\d]/g,''))+'">'+esc(s.profile_phone)+'</a>' : '') +
      '<p data-wait-since="'+esc(s.created_at)+'"></p>'+ (s.lat != null && s.lng != null ? '<a target="_blank" rel="noopener noreferrer" href="'+esc(UG_GEO.wazeUrl(s.lat,s.lng))+'">'+esc(T('notify.map'))+'</a>' : '') +
      '<div class="ug-notify-actions">'+button('sos',s.id,'notify.ack')+button('open-sos',s.id,'notify.openSos')+'</div></article>');
    pendingDispatch.forEach(d => { const r=d.report || {}; rows.push('<article class="ug-notify-card"><h2>'+esc(T('notify.dispatch'))+' · '+esc(r.code || d.report_id)+'</h2><p>'+esc(r.hazard_type || d.team)+' · '+esc(r.severity || '')+' · '+esc(r.barangay || '')+'</p><p>'+esc(d.instructions || '')+'</p><div class="ug-notify-actions">'+button('dispatch',d.id,'notify.ack')+button('decline',d.id,'notify.decline')+button('open-dispatch',d.id,'notify.open')+'</div></article>'); });
    overlay.className = 'ug-sos-overlay'; overlay.hidden = minimized || !rows.length;
    overlay.setAttribute('role','alertdialog'); overlay.setAttribute('aria-modal','true'); overlay.setAttribute('aria-live','assertive'); overlay.setAttribute('aria-labelledby','ug-notify-title');
    overlay.innerHTML = rows.length ? '<div class="ug-notify-panel"><h1 id="ug-notify-title">'+esc(T(visibleSos.length?'notify.sos':'notify.dispatch'))+': '+rows.length+'</h1><p>'+esc(T('notify.readNotAck'))+'</p>'+(error?'<p role="alert">'+esc(error)+'</p>':'')+rows.join('')+'<button class="ug-btn" data-ug-notify="minimize">'+esc(T('notify.minimize'))+'</button></div>' : '';
    paintCounters();
    if (!overlay.hidden && overlay.dataset.signature !== signature) {
      overlay.dataset.signature = signature; const first=overlay.querySelector('button'); if(first) first.focus();
    }
    paintEnrollment();
  }
  function paintCounters() {
    document.querySelectorAll('[data-wait-since]').forEach(el => {
      const seconds = Math.max(0,Math.floor((Date.now()-Date.parse(el.dataset.waitSince))/1000));
      el.textContent = T('notify.waiting')+' '+Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0')+(seconds>=settings().sos_ack_timeout_s?' · '+T('notify.unacknowledged'):'');
      el.classList.toggle('ug-notify-overdue',seconds>=settings().sos_ack_timeout_s);
    });
  }
  function setEnrollmentDismissed(value) {
    enrollmentDismissed = value;
    if (profile) {
      try { localStorage.setItem('ug.push.enrollment.dismissed.'+profile.id, value ? '1' : '0'); } catch (e) {}
    }
  }
  function paintEnrollment() {
    const el=host('ug-notify-enrollment'); el.className='ug-notify-enrollment';
    el.hidden=enrollmentDismissed || pushOn || (!responder() && !offerCitizen);
    if(el.hidden){el.innerHTML='';return;}
    const html='<div class="ug-notify-enrollment-head"><h3>'+esc(T('notify.enableAlerts'))+'</h3><button type="button" class="ug-ico-btn" data-ug-notify="dismiss-enrollment" aria-label="'+esc(T('notify.close'))+'">'+UG.icon('x',18)+'</button></div><p>'+esc(T('notify.ios'))+'</p>'+button('enable-push','','notify.allow')+button('test-push','','notify.testPush')+'<p>'+esc(T('notify.deliveryLimits'))+'</p>';
    setHTML(el,html);
  }
  async function deviceState() {
    if (!profile) return;
    const token=epoch;
    try {
      const c=Repo.client(); const enabled=await UG_PWA.pushEnabled();
      const result=await c.from('push_subscriptions').select('id,endpoint,user_agent,created_at').eq('user_id',profile.id).order('created_at',{ascending:false});
      if(token!==epoch)return;
      if(result.error)throw result.error;
      devices=result.data || []; pushOn=enabled;
      paint();
    } catch(e) { if(token===epoch){pushOn=false;paint();} }
  }
  async function refreshPending() {
    if (!profile || !Repo.client()) return;
    if (fetching) {again=true;return;}
    fetching=true; const token=epoch, version=revision, p=profile, c=Repo.client();
    try {
      let sos=c.from('sos_log').select('*').eq('status','sent').gte('created_at',new Date(Date.now()-86400000).toISOString()).order('created_at',{ascending:true}).limit(50);
      if(p.role==='barangay_official') sos=sos.eq('barangay_id',p.barangay_id);
      const [s,n,d,a]=await Promise.all([
        staffSos()?sos:Promise.resolve({data:[]}),
        c.from('notifications').select('*').eq('user_id',p.id).eq('requires_ack',true).is('acked_at',null).order('created_at',{ascending:true}).limit(200),
        p.role==='dispatch_team'?c.from('report_dispatches').select('*,report:reports(code,hazard_type,severity,barangay)').eq('unit_id',p.dispatch_unit_id).is('alarm_acked_at',null).not('dispatch_status','in','(done,declined)').order('dispatched_at',{ascending:true}).limit(200):Promise.resolve({data:[]}),
        c.rpc('get_alert_settings')
      ]);
      if(token!==epoch)return;
      for(const result of [s,n,d,a]) if(result.error)throw result.error;
      if(version!==revision){again=true;return;}
      hasConfirmed=true;
      pendingSos=s.data || []; pendingAck=n.data || []; pendingDispatch=d.data || [];
      UG.DATA.alertSettings=a.data || DEFAULTS;
      UG_NOTIF_STORE.mergeAll(pendingAck.map(Repo.toNotification)).catch(()=>{});
      if(!retry.size)error='';
      if(pendingSos.length===50 || pendingAck.length===200 || pendingDispatch.length===200)error=T('notify.capacity');
      cachePending();sync();
    } catch(e) { if(token===epoch){error=T('notify.syncFailed')+' '+(e.message||'');paint();} }
    finally {fetching=false; if(again){again=false;refreshPending();}}
  }
  function mergeEvent(table,row) {
    if(!profile || !row || !row.id)return;
    revision++;
    const merge=(rows,predicate)=>{const rest=rows.filter(x=>x.id!==row.id);return predicate(row)?rest.concat(row):rest;};
    if(table==='sos_log' && staffSos()) pendingSos=merge(pendingSos,r=>r.status==='sent'&&Date.parse(r.created_at)>Date.now()-86400000&&(profile.role!=='barangay_official'||r.barangay_id===profile.barangay_id));
    if(table==='notifications' && row.user_id===profile.id){pendingAck=merge(pendingAck,r=>r.requires_ack&&!r.acked_at);UG_NOTIF_STORE.mergeAll([Repo.toNotification(row)]).catch(()=>{});}
    if(table==='report_dispatches' && profile.role==='dispatch_team' && row.unit_id===profile.dispatch_unit_id) pendingDispatch=merge(pendingDispatch,r=>!r.alarm_acked_at&&!['done','declined'].includes(r.dispatch_status));
    hasConfirmed=true;cachePending();sync(); refreshPending();
  }
  function stop() {
    epoch++; hasConfirmed=false; const c=Repo.client(); if(c&&channel)c.removeChannel(channel); channel=null;
    enrollmentDismissed=false;
    clearInterval(poll);clearInterval(clock);profile=null;pendingSos=[];pendingAck=[];pendingDispatch=[];devices=[];pushOn=false;error='';retry.clear();busy.clear();urgentSeen.clear();overlaySignature='';
    UG_ALARM.stopAll(); ['ug-notify-banner','ug-notify-overlay','ug-notify-enrollment'].forEach(id=>{const el=document.getElementById(id);if(el)el.remove();});
    document.body.classList.remove('ug-has-notify-banner');
  }
  function start(p) {
    if(!p||p.disabled){stop();return;}
    if(profile && profile.id===p.id && profile.role===p.role && profile.dispatch_unit_id===p.dispatch_unit_id && profile.barangay_id===p.barangay_id && profile.is_super_admin===p.is_super_admin)return;
    stop();profile=p;minimized=superAdmin();offerCitizen=false;
    try { enrollmentDismissed=localStorage.getItem('ug.push.enrollment.dismissed.'+p.id)==='1'; } catch (e) {}
    const c=Repo.client(); if(!c)return;
    channel=c.channel('ug-pending-'+p.id);
    [['notifications','user_id=eq.'+p.id],['sos_log',null],['report_dispatches',p.role==='dispatch_team'?'unit_id=eq.'+p.dispatch_unit_id:null]].forEach(([table,scope])=>{
      ['INSERT','UPDATE'].forEach(event=>channel.on('postgres_changes',Object.assign({event,schema:'public',table},scope?{filter:scope}:{}),payload=>mergeEvent(table,payload.new)));
    });
    if(superAdmin())channel.on('postgres_changes',{event:'INSERT',schema:'public',table:'change_requests'},refreshPending);
    channel.subscribe(status=>{if(status==='SUBSCRIBED')refreshPending();});
    refreshPending();deviceState();
    if(UG_PWA.repairPush) UG_PWA.repairPush().then(deviceState).catch(()=>{});
    UG_SETTINGS.loadNotificationPrefs().catch(()=>{});
    const token=epoch;
    Promise.all([UG_NOTIF_STORE.listFor(p.id),UG_NOTIF_STORE.pendingSnapshot(p.id)]).then(([rows,cached])=>{
      if(token!==epoch || hasConfirmed)return;
      UG.DATA.notifications=rows;
      if(p.role==='dispatch_team' && window.UG_DISPATCH)UG_DISPATCH.state.data.notifications=rows;
      if(cached && cached.scope===[p.role,p.barangay_id,p.dispatch_unit_id,p.is_super_admin].join('|')){
        pendingSos=cached.pendingSos || [];pendingAck=cached.pendingAck || [];pendingDispatch=cached.pendingDispatch || [];
        error=T('notify.syncFailed');sync();
      }
      if(app()?.S.session)app().render();
    }).catch(()=>{});
    poll=setInterval(()=>{if(!document.hidden){refreshPending();deviceState();}},15000);
    clock=setInterval(paintCounters,1000);paint();
  }
  async function acknowledge(kind,id) {
    if(!profile)return; const key=kind+':'+id; if(busy.has(key))return;
    busy.add(key); const token=epoch;error='';
    try {
      const c=Repo.client();if(!c || navigator.onLine===false)throw new Error(T('notify.offline'));
      if(kind==='sos')await Repo.updateSosStatus(id,'acknowledged');
      else {const r=await c.rpc(kind==='dispatch'?'dispatch_ack_alarm':'ack_notification',kind==='dispatch'?{p_dispatch_id:id}:{p_id:id});if(r.error)throw r.error;}
      if(token!==epoch)return;
      revision++; retry.delete(key);
      if(kind==='sos'){pendingSos=pendingSos.filter(s=>s.id!==id);pendingAck=pendingAck.filter(n=>n.sos_id!==id || !['sos','sos_escalation'].includes(n.type));}
      else if(kind==='dispatch'){pendingDispatch=pendingDispatch.filter(d=>d.id!==id);pendingAck=pendingAck.filter(n=>n.dispatch_id!==id);}
      else pendingAck=pendingAck.filter(n=>n.id!==id);
      cachePending();sync();await refreshPending();return true;
    } catch(e) { if(token===epoch){error=T('notify.ackFailed')+' '+(e.message||'');if(navigator.onLine===false || /fetch|network|offline/i.test(e.message||''))retry.set(key,{kind,id});paint();} return false; }
    finally {busy.delete(key);if(token===epoch)paint();}
  }
  function openItem(n) {
    const a=app();if(!profile || !a || !a.S.session){pendingOpen=n;return;}
    minimized=true;paint();
    if(n.sos_id && n.type!=='lost_signal'){
      a.go('sos');a.render();
      if(staffSos()){
        const show=row=>{if(!row){showExpanded(n);return;}UG.DATA.sosLog=(UG.DATA.sosLog || []).filter(s=>s.id!==row.id).concat(Object.assign({time:UG_UTIL.relTime(row)},row));UG_SOS.sosDetailModal(a.S,row.id);};
        Repo.client().from('sos_log').select('*').eq('id',n.sos_id).maybeSingle().then(r=>{if(r.error)throw r.error;show(r.data);}).catch(e=>{a.toast(e.message,'warning');show(pendingSos.find(s=>s.id===n.sos_id));});
      }return;
    }
    if(profile.role==='dispatch_team'){
      const route=n.dispatch_id?'dispatch-detail':({patient_notice:'hospital',unit_request:'requests',support_request:'requests',dispatch_help:'dispatch',help_request:'dispatch',relief_escort:'contacts'}[n.type]||'notifications');
      if(n.dispatch_id)UG_DISPATCH.state.openDispatchId=n.dispatch_id;
      UG_DISPATCH.state.route=route;a.go(route);a.render();a.loadRouteData(route);if(route==='notifications')showExpanded(n);return;
    }
    if(n.change_request_id && superAdmin()){
      a.go('hotlines');Promise.resolve(a.loadRouteData('hotlines')).then(async()=>{
        const r=await Repo.client().from('change_requests').select('*').eq('id',n.change_request_id).maybeSingle();
        if(r.error)throw r.error;if(!r.data){showExpanded(n);return;}
        UG.DATA.changeRequests=(UG.DATA.changeRequests || []).filter(x=>x.id!==r.data.id).concat(r.data);
        a.render();a.actions['open-change-request']({id:n.change_request_id});
      }).catch(e=>{a.toast(e.message,'warning');showExpanded(n);});return;
    }
    // Pending items can be older than Repo's recent incident/advisory lists.
    if(n.report_id && n.type!=='lost_signal' && !(UG.DATA.incidents || []).some(i=>i.uuid===n.report_id)){
      const c=Repo.client();if(!c){showExpanded(n);return;}
      c.from('reports_feed').select('*').eq('id',n.report_id).maybeSingle().then(r=>{
        if(r.error)throw r.error;if(!r.data){showExpanded(n);return;}
        UG.DATA.incidents=(UG.DATA.incidents || []).concat(Repo.toIncident(r.data));openItem(n);
      }).catch(e=>{a.toast(e.message,'warning');showExpanded(n);});return;
    }
    if(n.advisory_id && !(UG.DATA.advisories || []).some(x=>x.id===n.advisory_id)){
      const c=Repo.client();if(!c){showExpanded(n);return;}
      c.from('advisories').select('*').eq('id',n.advisory_id).maybeSingle().then(r=>{
        if(r.error)throw r.error;if(!r.data){showExpanded(n);return;}
        UG.DATA.advisories=(UG.DATA.advisories || []).concat(Repo.toAdvisory(r.data));openItem(n);
      }).catch(e=>{a.toast(e.message,'warning');showExpanded(n);});return;
    }
    const routes=['sos','incident','report-detail','advisory-detail','roadwork','relief','centers','hotlines','notifications','dispatch-units','tracking'];
    let route=n.target_route, id=n.target_id;
    if(['unit_request','support_request'].includes(n.type))route='dispatch-units';
    if(n.type==='lost_signal' && staffSos()){route='tracking';id=n.dispatch_id;setTimeout(()=>UG_TRACKING.choose(id),0);}
    else if(n.report_id){route=profile.role==='citizen'?'report-detail':'incident';id=n.report_id;}
    else if(n.advisory_id){route='advisory-detail';id=n.advisory_id;}
    else if(n.road_work_id){route='roadwork';id=n.road_work_id;}
    else if(n.relief_id){route='relief';id=n.relief_id;}
    if(!routes.includes(route) || route==='notifications'){route='notifications';expanded=n;}
    a.go(route);a.S.openId=id || null;a.render();Promise.resolve(a.loadRouteData(route)).catch(e=>a.toast(e.message,'warning'));
    if(route==='notifications')showExpanded(n);
  }
  function showExpanded(n){const el=host('ug-notify-expanded');el.className='ug-notify-enrollment';el.innerHTML='<h3>'+esc(n.title)+'</h3><p>'+esc(n.body)+'</p><button class="ug-btn" data-ug-notify="close-expanded">'+esc(T('notify.close'))+'</button>';}
  function pendingCount(){return pendingAck.length+pendingSos.filter(s=>!pendingAck.some(n=>n.sos_id===s.id)).length+pendingDispatch.filter(d=>!pendingAck.some(n=>n.dispatch_id===d.id)).length;}
  function isPending(type,id){return type==='sos'?pendingSos.some(s=>s.id===id):type==='dispatch'?pendingDispatch.some(d=>d.id===id):pendingAck.some(n=>n.id===id);}
  function pinnedHTML(){return !pendingAck.length?'':'<section class="ug-notify-pinned"><h3>'+esc(T('notify.needsAck'))+'</h3><p>'+esc(T('notify.readNotAck'))+'</p>'+pendingAck.map(n=>'<article><strong>'+esc(n.title)+'</strong><p>'+esc(n.body)+'</p>'+button('open-notification',n.id,'notify.open')+(!n.sos_id&&!n.dispatch_id&&!n.change_request_id&&!['escalation_1h','dispatch_needed','lost_signal'].includes(n.type)?button('notification',n.id,'notify.ack'):'')+'</article>').join('')+'</section>';}
  function filteredRows(rows){return (rows||[]).filter(n=>(filter!=='unread'||(Object.prototype.hasOwnProperty.call(n,'unread')?n.unread:!n.read_at))&&(filter!=='urgent'||['critical','urgent'].includes(n.priority))&&(!typeFilter||n.type===typeFilter));}
  function filtersHTML(rows){return '<div class="ug-notify-filters"><label>'+esc(T('notify.filter'))+' <select data-ug-notify-filter><option value="all"'+(filter==='all'?' selected':'')+'>'+esc(T('notify.all'))+'</option><option value="unread"'+(filter==='unread'?' selected':'')+'>'+esc(T('notify.unread'))+'</option><option value="urgent"'+(filter==='urgent'?' selected':'')+'>'+esc(T('notify.urgent'))+'</option></select></label><select aria-label="'+esc(T('notify.type'))+'" data-ug-notify-type><option value="">'+esc(T('notify.allTypes'))+'</option>'+Array.from(new Set((rows||[]).map(n=>n.type).filter(Boolean))).map(type=>'<option'+(type===typeFilter?' selected':'')+' value="'+esc(type)+'">'+esc(type)+'</option>').join('')+'</select></div>';}
  function badgeHTML(){const n=pendingCount();return '<span class="ug-action-count" data-ug-action-count aria-label="'+esc(T('notify.needsAck'))+'"'+(n?'':' hidden')+'>'+n+'</span>';}
  function devicesHTML(){return '<div class="ug-card"><div class="ug-card-b"><h3>'+esc(T('notify.devices'))+'</h3><p>'+esc(T(pushOn?'notify.alertsOn':'notify.alertsOff'))+'</p>'+devices.map(d=>'<p>'+esc(d.user_agent || T('notify.device'))+' · '+esc(new Date(d.created_at).toLocaleDateString('en-PH',{timeZone:'Asia/Manila'}))+' '+button('remove-device',d.id,'notify.remove')+'</p>').join('')+button('test-push','','notify.testPush')+(responder()?button('test-sos','','notify.testSos'):'')+'</div></div>';}
  function settingsHTML(){if(!superAdmin())return '';const s=settings();return '<form class="ug-card ug-alert-settings" id="ug-alert-settings"><div class="ug-card-b"><h3>'+esc(T('notify.settings'))+'</h3>'+Object.keys(DEFAULTS).map(k=>'<label>'+esc(T('notify.setting.'+k))+(k==='super_admin_sos_alarm'?'<select name="'+k+'"><option value="backstop"'+(s[k]==='backstop'?' selected':'')+'>'+esc(T('notify.backstop'))+'</option><option value="every"'+(s[k]==='every'?' selected':'')+'>'+esc(T('notify.every'))+'</option></select>':'<input required type="number" step="1" name="'+k+'" value="'+esc(s[k])+'">')+'<small>'+esc(T('notify.help.'+k))+'</small></label>').join('')+'<p>'+esc(T('notify.changed'))+' '+esc(s.updated_by_name || '—')+' · '+esc(s.updated_at || '—')+'</p>'+button('save-settings','','notify.save')+button('reset-settings','','notify.reset')+'</div></form>';}
  async function saveSettings(reset){const values=reset?Object.assign({},DEFAULTS):{};if(!reset)new FormData(document.getElementById('ug-alert-settings')).forEach((v,k)=>values[k]=k==='super_admin_sos_alarm'?v:Number(v));const r=await Repo.client().rpc('set_alert_settings',{p_values:values});if(r.error)throw r.error;UG.DATA.alertSettings=r.data;sync();if(app())app().render();}
  function offerEnrollment(){if(profile && profile.role==='citizen'){const k='ug.push.prompt.'+profile.id;if(!localStorage.getItem(k)){localStorage.setItem(k,'1');offerCitizen=true;deviceState();}}}
  document.addEventListener('click',async event=>{
    const b=event.target.closest('[data-ug-notify]');if(!b)return;event.preventDefault();const action=b.dataset.ugNotify,id=b.dataset.id || '';
    try {
      if(['sos','dispatch','notification'].includes(action))await acknowledge(action,id);
      else if(action==='minimize'){minimized=true;paint();}
      else if(action==='expand'){minimized=false;paint();if(!pendingSos.length&&!pendingDispatch.length){if(app()){app().go('notifications');app().render();}}}
      else if(action==='unlock'){UG_ALARM.unlock();setTimeout(paint,200);}
      else if(action==='open-sos')openItem({sos_id:id});
      else if(action==='open-dispatch')openItem({dispatch_id:id});
      else if(action==='decline'){minimized=true;paint();if(app())app().actions['dispatch-decline']({id});}
      else if(action==='open-notification'){const n=pendingAck.find(n=>n.id===id);if(n){Repo.markRead(id).catch(()=>{});openItem(n);}}
      else if(action==='dismiss-enrollment'){setEnrollmentDismissed(true);paintEnrollment();document.querySelector('#ug-notify-banner [data-ug-notify="enroll"]')?.focus();}
      else if(action==='enroll'){setEnrollmentDismissed(false);offerCitizen=true;paintEnrollment();document.querySelector('#ug-notify-enrollment [data-ug-notify="dismiss-enrollment"]')?.focus();}
      else if(action==='enable-push'){await UG_PWA.enablePush();await deviceState();}
      else if(action==='test-push'){const r=await Repo.client().functions.invoke('push-dispatch',{body:{selfTest:true}});if(r.error)throw r.error;if(!r.data?.sent)throw new Error(T('notify.noDevice'));if(app())app().toast(T('notify.testSent'),'prepared');}
      else if(action==='remove-device'){const r=await Repo.client().from('push_subscriptions').delete().eq('id',id).eq('user_id',profile.id);if(r.error)throw r.error;await deviceState();if(app())app().render();}
      else if(action==='test-sos' && responder()){UG_ALARM.unlock();UG_ALARM.loop('sos-test','sos');setTimeout(()=>UG_ALARM.stop('sos-test'),3000);}
      else if(action==='save-settings'||action==='reset-settings')await saveSettings(action==='reset-settings');
      else if(action==='close-expanded'){const el=document.getElementById('ug-notify-expanded');if(el)el.remove();}
    }catch(e){error=e.message || T('notify.syncFailed');paint();if(app())app().toast(error,'warning');}
  });
  document.addEventListener('submit',event=>{if(event.target.id==='ug-alert-settings'){event.preventDefault();saveSettings(false).catch(e=>{if(app())app().toast(e.message,'warning');});}});
  document.addEventListener('keydown',event=>{
    const overlay=document.getElementById('ug-notify-overlay');if(!overlay || overlay.hidden || event.key!=='Tab')return;
    const items=Array.from(overlay.querySelectorAll('button:not(:disabled),a[href]'));if(!items.length)return;
    const first=items[0],last=items[items.length-1];
    if(event.shiftKey && (document.activeElement===first || !overlay.contains(document.activeElement))){event.preventDefault();last.focus();}
    else if(!event.shiftKey && (document.activeElement===last || !overlay.contains(document.activeElement))){event.preventDefault();first.focus();}
  });
  document.addEventListener('change',event=>{if(event.target.matches('[data-relief-phase]')){const el=event.target;el.disabled=true;Repo.updateRelief(el.dataset.reliefPhase,{phase:el.value}).then(()=>{if(app())app().render();}).catch(e=>{el.disabled=false;if(app())app().toast(e.message,'warning');});}if(event.target.matches('[data-ug-notify-filter]')){filter=event.target.value;if(app())app().render();}if(event.target.matches('[data-ug-notify-type]')){typeFilter=event.target.value;if(app())app().render();}});
  document.addEventListener('ug:alarm-unlocked',paint);
  ['focus','online'].forEach(event=>window.addEventListener(event,()=>{refreshPending();deviceState();if(event==='online')Array.from(retry.values()).forEach(r=>acknowledge(r.kind,r.id));}));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){refreshPending();deviceState();}});
  if(navigator.serviceWorker)navigator.serviceWorker.addEventListener('message',event=>{if(['ug-push','ug-open'].includes(event.data?.type)){refreshPending();if(event.data.type==='ug-open'&&event.data.payload)openItem(event.data.payload);}if(event.data?.type==='ug-subscription-change')UG_PWA.enablePush().then(deviceState).catch(()=>{pushOn=false;paint();});});
  function handlePendingOpen(){
    if(!profile || !app()?.S.session)return;
    if(pendingOpen){const n=pendingOpen;pendingOpen=null;openItem(n);return;}
    const url=new URL(location.href),id=url.searchParams.get('ug_notification');if(!id)return;
    url.searchParams.delete('ug_notification');history.replaceState(null,'',url.href);
    Repo.client().from('notifications').select('*').eq('id',id).eq('user_id',profile.id).maybeSingle().then(r=>{if(r.data)openItem(r.data);});
  }
  Auth.onChange(state=>{if(!state.profile){const el=document.getElementById('ug-notify-expanded');if(el)el.remove();}start(state.profile);});
  return {start,stop,refreshPending,ackSos:id=>acknowledge('sos',id),ackNotification:id=>acknowledge('notification',id),ackDispatch:id=>acknowledge('dispatch',id),
    pendingCount,isPending,onChange(fn){listeners.add(fn);return()=>listeners.delete(fn);},pinnedHTML,badgeHTML,handlePendingOpen,filtersHTML,filteredRows,openItem,devicesHTML,settingsHTML,offerEnrollment,deviceState,
    snapshot:()=>({pendingSos:pendingSos.slice(),pendingAck:pendingAck.slice(),pendingDispatch:pendingDispatch.slice()}),defaults:DEFAULTS};
})();
window.UG_NOTIFY=UG_NOTIFY;
