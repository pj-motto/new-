/* UniGuard · read-only live dispatch tracking; database RLS defines the scope. */
const UG_TRACKING=(function(){
  const esc=UG_UTIL.esc,T=k=>UG_I18N.t(k);
  let rows=[],selected=null,search='',statusFilter='',channel=null,timer=null,debounce=null,map=null,mapEl=null,layers=null,trail=[],generation=0,error='';
  let events=[],sosRows=[];
  const profile=()=>Auth.state.profile;
  const allowed=()=>profile()&&['lgu_ldrrmc','barangay_official'].includes(profile().role);
  const open=d=>!['done','declined'].includes(d.dispatch_status);
  const date=value=>value?new Date(value).toLocaleString(UG_I18N.isFil()?'fil-PH':'en-PH',{timeZone:'Asia/Manila',hour12:false}):'—';
  const settings=()=>Object.assign({},UG_NOTIFY.defaults,UG.DATA.alertSettings || {});
  function signal(d,now=Date.now()){
    const seconds=Math.max(0,(now-Date.parse(d.last_loc_at || d.dispatched_at))/1000);
    if(!Number.isFinite(seconds)||seconds>=settings().signal_lost_s)return 'lost';
    if(!d.last_loc_at||seconds>=settings().signal_amber_s)return 'amber';
    return 'good';
  }
  function eta(d){const r=d.report || {};
    if(signal(d)==='lost' || d.last_accuracy>150)return null;
    if(![d.last_lat,d.last_lng,r.lat,r.lng].every(v=>typeof v==='number'&&Number.isFinite(v)))return null;
    if(['on_scene','under_control','fire_out','arrived_hospital','done'].includes(d.dispatch_status))return 0;
    return Math.max(1,Math.ceil(UG_UTIL.distanceM(d.last_lat,d.last_lng,r.lat,r.lng)/(settings().eta_speed_kmh*1000/60)));
  }
  function screen(){if(!allowed())return '<p>'+esc(T('notify.trackingHelp'))+'</p>';
    return '<div class="ug-col" style="gap:16px"><h2>'+esc(T('notify.tracking'))+'</h2><p>'+esc(T('notify.trackingHelp'))+'</p>'+UG_NOTIFY.pinnedHTML()+
      '<div class="ug-notify-filters"><input class="ug-input" data-ug-track-search aria-label="'+esc(T('notify.search'))+'" placeholder="'+esc(T('notify.search'))+'" value="'+esc(search)+'">'+
      '<select data-ug-track-status aria-label="'+esc(T('label.status'))+'"><option value="">'+esc(T('notify.all'))+'</option>'+['sent','acknowledged','en_route','on_scene','under_control','fire_out','on_hold','transporting','arrived_hospital'].map(s=>'<option value="'+s+'"'+(statusFilter===s?' selected':'')+'>'+esc(T('status.'+s)===('status.'+s)?s:T('status.'+s))+'</option>').join('')+'</select></div>'+
      '<p data-ug-track-error role="status"></p><div class="ug-tracking-layout"><div><div data-ug-track-map class="ug-tracking-map" role="img" aria-label="'+esc(T('notify.tracking'))+'"></div><div data-ug-track-results></div></div><aside data-ug-track-detail class="ug-tracking-detail"></aside></div></div>';
  }
  function filtered(){return rows.filter(d=>open(d)&&(!statusFilter||d.dispatch_status===statusFilter)&&(!search||[d.team,d.unit?.name,d.report?.code,d.report?.barangay].join(' ').toLowerCase().includes(search.toLowerCase())));}
  function signalHTML(d){const s=signal(d);return '<span class="ug-track-signal ug-track-signal--'+s+'">'+esc(T(s==='good'?'notify.signalGood':s==='amber'?'notify.signalAmber':'notify.signalLost'))+'</span>';}
  function paint(){const result=document.querySelector('[data-ug-track-results]');if(!result)return;
    const list=filtered();result.innerHTML=list.length?'<div class="ug-tracking-list">'+list.map(d=>'<button class="ug-card ug-tracking-row'+(selected===d.id?' is-selected':'')+'" data-ug-track="'+esc(d.id)+'"><strong>'+esc(d.unit?.name || d.team)+'</strong><span>'+esc(d.report?.code || '')+' · '+esc(d.report?.barangay || '')+'</span>'+signalHTML(d)+'<span>'+esc(d.dispatch_status)+' · '+esc(d.last_loc_at?date(d.last_loc_at):T('notify.noFix'))+'</span></button>').join('')+'</div>':'<p>'+esc(T('notify.noTracking'))+'</p>';
    const err=document.querySelector('[data-ug-track-error]');if(err)err.textContent=error;
    drawMap(list);paintDetail();
  }
  function timelineHTML(s,dispatches,dispatchEvents){
    const list=[];const add=(at,label,who,automatic)=>{if(at)list.push({at,label,who,automatic});};
    if(s){add(s.created_at,T('notify.received'),s.profile_name,false);add(s.acked_at,T('notify.ack'),s.acked_by_name,false);add(s.resolved_at,T('notify.resolved'),s.resolved_by_name,false);}
    (dispatches||[]).forEach(d=>{
      const name=d.unit?.name || (UG.DATA.unitsById || {})[d.unit_id]?.name || d.team;
      add(d.dispatched_at,name+' · '+T('notify.dispatch'),d.dispatched_by_name,!!d.auto_dispatched);
      const ev=(dispatchEvents || []).filter(e=>e.dispatch_id===d.id);
      if(d.alarm_acked_at)add(d.alarm_acked_at,name+' · '+T('notify.ack'),ev.find(e=>e.action==='alarm_acknowledged'||(e.action==='acknowledged'&&!/^Automatic:/.test(e.note || '')))?.actor_name || d.alarm_acked_by,false);
      ev.filter(e=>e.action!=='dispatched'&&e.action!=='alarm_acknowledged').forEach(e=>add(e.created_at,name+' · '+e.action+(e.note?' · '+e.note:''),e.actor_name,/^Automatic:/.test(e.note || '')));
      if(!ev.length){[['ack_at','acknowledged'],['en_route_at','en_route'],['on_scene_at','on_scene'],['done_at','done']].forEach(([at,label])=>add(d[at],name+' · '+label,'',false));}
    });
    return '<h3>'+esc(T('notify.timeline'))+'</h3><ol class="ug-response-timeline">'+list.sort((a,b)=>Date.parse(a.at)-Date.parse(b.at)).map(e=>'<li><time>'+esc(date(e.at))+'</time><strong>'+esc(e.label)+'</strong><span>'+esc(e.automatic?T('notify.automatic'):e.who?T('notify.by')+' '+e.who:'')+'</span></li>').join('')+'</ol>';
  }
  function paintDetail(){const el=document.querySelector('[data-ug-track-detail]');if(!el)return;
    const d=rows.find(d=>d.id===selected);if(!d){el.innerHTML='<p>'+esc(T('notify.open'))+' · '+esc(T('notify.team'))+'</p>';return;}
    const arrival=eta(d),s=sosRows.find(s=>s.report_id===d.report_id);
    el.innerHTML='<h3>'+esc(d.unit?.name || d.team)+'</h3><p>'+esc(d.report?.code || '')+' · '+esc(d.report?.barangay || '')+'</p>'+signalHTML(d)+'<p>'+esc(T('notify.lastFix'))+': '+esc(date(d.last_loc_at))+'</p><p>'+esc(T('notify.accuracy'))+': '+esc(d.last_accuracy ?? '—')+'</p><p>'+esc(T('notify.eta'))+': '+(arrival===null?'—':arrival+' min')+'</p><small>'+esc(T('notify.etaHelp'))+'</small><p>'+esc(d.instructions || '')+'</p><button class="ug-btn" data-act="open-incident" data-id="'+esc(d.report_id)+'">'+esc(T('notify.open'))+'</button>'+timelineHTML(s,rows.filter(x=>x.report_id===d.report_id),events);
  }
  function drawMap(list){if(!map||!layers)return;layers.clearLayers();const L=window.L;
    list.forEach(d=>{
      const r=d.report || {},color=signal(d)==='lost'?'#b4132b':signal(d)==='amber'?'#ba7200':'#087f5b';
      if(Number.isFinite(d.last_lat)&&Number.isFinite(d.last_lng)){
        const marker=L.circleMarker([d.last_lat,d.last_lng],{radius:selected===d.id?12:8,color,fillColor:color,fillOpacity:.85}).bindTooltip(esc(d.unit?.name || d.team)+' · '+esc(r.code || ''));
        marker.on('click',()=>choose(d.id));marker.addTo(layers);
        if(selected===d.id&&d.last_accuracy>0)L.circle([d.last_lat,d.last_lng],{radius:Math.min(d.last_accuracy,2000),color,weight:1,fillOpacity:.08}).addTo(layers);
      }
      if(selected===d.id&&Number.isFinite(r.lat)&&Number.isFinite(r.lng))L.circleMarker([r.lat,r.lng],{radius:9,color:'#771222',fillColor:'#fff',fillOpacity:1}).bindTooltip(esc(r.code || d.report_id)).addTo(layers);
    });
    if(trail.length>1)L.polyline(trail.map(p=>[p.lat,p.lng]),{color:'#315a9c',weight:3}).addTo(layers);
  }
  async function load(){if(!allowed()||!Repo.client())return;const ticket=++generation;
    try{const result=await Repo.client().from('report_dispatches').select('*,unit:dispatch_units(name),report:reports(code,hazard_type,severity,barangay,lat,lng)').not('dispatch_status','in','(done,declined)').order('dispatched_at',{ascending:false}).limit(400);if(result.error)throw result.error;if(ticket!==generation)return;rows=result.data || [];error=rows.length===400?T('notify.capacity'):'';paint();if(selected)await loadDetail();}
    catch(e){if(ticket===generation){error=T('notify.syncFailed')+' '+e.message;paint();}}
  }
  async function loadDetail(){const d=rows.find(d=>d.id===selected);if(!d)return;const id=selected;
    const c=Repo.client();const group=rows.filter(x=>x.report_id===d.report_id).map(x=>x.id);
    const [positions,ev,sos]=await Promise.all([c.from('dispatch_locations').select('lat,lng,accuracy,captured_at').eq('dispatch_id',id).order('captured_at',{ascending:false}).limit(100),c.from('report_dispatch_events').select('*').in('dispatch_id',group).order('created_at',{ascending:true}).limit(500),c.from('sos_log').select('*').eq('report_id',d.report_id).limit(1)]);
    if(id!==selected||!allowed())return;
    trail=positions.error?[]:(positions.data || []).reverse();events=ev.data || [];sosRows=sos.data || [];paint();
  }
  function choose(id){selected=id;trail=[];paint();loadDetail();const d=rows.find(d=>d.id===id);if(map&&d?.last_lat!=null)map.setView([d.last_lat,d.last_lng],15);}
  function mount(){const el=document.querySelector('[data-ug-track-map]');if(!el||!allowed()){stop();return;}
    if(mapEl!==el){if(map){map.remove();map=null;}mapEl=el;
      if(window.L){map=L.map(el).setView([16.012,120.23],13);L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap contributors'}).addTo(map);layers=L.layerGroup().addTo(map);}
    }
    if(!channel){channel=Repo.client()?.channel('ug-tracking-'+profile().id).on('postgres_changes',{event:'*',schema:'public',table:'report_dispatches'},()=>{clearTimeout(debounce);debounce=setTimeout(load,350);}).subscribe(status=>{if(status==='SUBSCRIBED')load();});timer=setInterval(()=>{if(!document.hidden)load();},15000);load();}
    paint();
  }
  function stop(){generation++;if(channel&&Repo.client())Repo.client().removeChannel(channel);channel=null;clearInterval(timer);clearTimeout(debounce);if(map)map.remove();map=null;mapEl=null;layers=null;}
  async function fillTimeline(s){const c=Repo.client();if(!c)return;const ds=s.report_id?await c.from('report_dispatches').select('*').eq('report_id',s.report_id):{data:[]};const ids=(ds.data||[]).map(d=>d.id);const ev=ids.length?await c.from('report_dispatch_events').select('*').in('dispatch_id',ids).order('created_at',{ascending:true}).limit(500):{data:[]};const el=document.querySelector('[data-sos-timeline="'+s.id+'"]');if(el)el.innerHTML=timelineHTML(s,ds.data || [],ev.data || []);}
  document.addEventListener('input',e=>{if(e.target.matches('[data-ug-track-search]')){search=e.target.value;paint();}});
  document.addEventListener('change',e=>{if(e.target.matches('[data-ug-track-status]')){statusFilter=e.target.value;paint();}});
  document.addEventListener('click',e=>{const b=e.target.closest('[data-ug-track]');if(b)choose(b.dataset.ugTrack);});
  Auth.onChange(s=>{if(!s.profile){stop();rows=[];selected=null;search='';statusFilter='';trail=[];events=[];sosRows=[];}});
  window.addEventListener('online',()=>{if(mapEl)load();});window.addEventListener('focus',()=>{if(mapEl)load();});
  return {screen,mount,stop,load,choose,signal,eta,timelineHTML,fillTimeline};
})();
window.UG_TRACKING=UG_TRACKING;
