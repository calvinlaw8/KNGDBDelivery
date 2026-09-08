const pairing=document.querySelector('#pairing');
const workspace=document.querySelector('#workspace');
const editor=document.querySelector('#config');
const form=document.querySelector('#form');
const issues=document.querySelector('#issues');
const statusText=document.querySelector('#status');
const importFile=document.querySelector('#import-file');
const componentNames=['redis','rabbitmq','mongodb','mysql'];
const labels={redis:'Redis',rabbitmq:'RabbitMQ',mongodb:'MongoDB',mysql:'MySQL'};
const roles={redis:['master','replica','replica'],rabbitmq:['seed','member','member'],mongodb:['primary','secondary','secondary'],mysql:['primary','replica','replica']};
const serviceFields={redis:[['port','服务端口','number',6379],['sentinel_port','Sentinel 端口','number',26379],['sentinel_master_name','主节点名称','text','mymaster']],rabbitmq:[['management_port','管理端口','number',15672],['admin_user','管理员账号','text','admin']],mongodb:[['port','服务端口','number',27017],['replica_set','副本集名称','text','rs0'],['admin_user','管理员账号','text','admin']],mysql:[['port','服务端口','number',3306],['replication_user','复制账号','text','repl'],['vip_verify_user','VIP 验证账号','text','ecopilot_vip_verify'],['vip','VIP','text',''],['vip_prefix','VIP 前缀','number',24],['keepalived_interface','Keepalived 网卡','text','ens160'],['keepalived_router_id','VRRP Router ID','number',51]]};
const secretFields={redis:[['redis_password','Redis 密码']],rabbitmq:[['rabbitmq_cookie','节点间 Cookie'],['rabbitmq_admin_password','管理员密码']],mongodb:[['mongodb_admin_password','管理员密码']],mysql:[['mysql_root_password','Root 密码'],['mysql_replication_password','复制密码'],['mysql_vip_verify_password','VIP 验证密码'],['keepalived_auth_password','Keepalived 认证密码']]};
let revision=0;
let draft=emptyDraft();
let validationTimer;
let validationController;
let latestIssues=[];
let pendingImport;
let pendingDeployment;
let deploymentStatusTimer;
let deploymentStatusRequest=false;
const manualTopologyPaths=new Set();

function emptyDraft(){return{schema_version:1,deployment:{components:['redis']},management:{ip:'',hostname:''},ssh:{management_user:'sysadmin',database_user:'sysadmin'},components:{redis:emptyComponent('redis')},secrets:{management_ssh_password:'',database_ssh_password:'',redis_password:''}}}
function emptyComponent(name){const service={};serviceFields[name].forEach(([key,,,value])=>service[key]=value);return{nodes:roles[name].map(role=>({ip:'',hostname:'',role})),service}}
function escapeText(value){return String(value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function field(path,label,type='text',value=''){return`<label>${label}<input data-path="${path}" type="${type}" value="${escapeText(value)}" ${type==='password'?'autocomplete="new-password"':''}></label>`}
function secretField(path,label,value=''){return`<label>${label}<span class=\"secret-control\"><input data-path=\"${path}\" type=\"password\" value=\"${escapeText(value)}\" autocomplete=\"new-password\"><span class=\"secret-actions\"><button data-secret-generate=\"${path}\" type=\"button\">生成</button><button data-secret-visibility=\"${path}\" type=\"button\">显示</button><button data-secret-copy=\"${path}\" type=\"button\">复制</button></span></span><span class=\"secret-status\" data-secret-status=\"${path}\" aria-live=\"polite\"></span></label>`}
function selected(){return draft.deployment.components}
function sectionForPath(path){if(path.indexOf('/components/')===0)return path.indexOf('/nodes/')>0?'topology':'services';if(path.indexOf('/deployment/')===0)return'components';if(path.indexOf('/secrets/')===0)return path==='/secrets/management_ssh_password'||path==='/secrets/database_ssh_password'?'management':'secrets';return'management'}
function controlForPath(path){return Array.from(form.querySelectorAll('[data-path]')).find(control=>control.dataset.path===path)}
function clearFieldIssues(){form.querySelectorAll('.field-error').forEach(error=>error.remove());form.querySelectorAll('[aria-invalid="true"]').forEach(control=>{control.removeAttribute('aria-invalid');control.removeAttribute('aria-describedby')})}
function renderIssues(items){
	latestIssues=items;
	clearFieldIssues();
	issues.replaceChildren();
	if(!items.length){issues.textContent='未发现问题';return}
	const list=document.createElement('ul');
	items.forEach((item,index)=>{
		const entry=document.createElement('li');
		const link=document.createElement('button');
		link.type='button';link.className=`issue-link ${item.severity}`;link.dataset.issuePath=item.path;link.textContent=`${item.severity.toUpperCase()} ${item.path}: ${item.message}`;entry.appendChild(link);list.appendChild(entry);
		if(item.severity!=='error')return;
		const control=controlForPath(item.path);
		if(!control)return;
		const error=document.createElement('span');
		error.className='field-error';error.id=`field-error-${index}`;error.textContent=item.message;control.setAttribute('aria-invalid','true');control.setAttribute('aria-describedby',error.id);control.closest('label').appendChild(error);
	});
	issues.appendChild(list);
	document.querySelectorAll('[data-requires-valid]').forEach(button=>button.disabled=items.some(item=>item.severity==='error'));
}
function showLocalIssue(control){
	clearFieldIssues();
	const value=control.value.trim();
	let message='';
	if(!value)message='此字段不能为空';
	else if(/\/(ip|vip)$/.test(control.dataset.path)&&!/^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$/.test(value))message='请输入有效的 IPv4 地址';
	else if(/\/hostname$/.test(control.dataset.path)&&!/^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])$/.test(value))message='请输入有效的主机名';
	if(!message)return;
	const error=document.createElement('span');error.className='field-error';error.id='local-field-error';error.textContent=message;control.setAttribute('aria-invalid','true');control.setAttribute('aria-describedby',error.id);control.closest('label').appendChild(error);
}
function topologyBlock(name){
	const nodes=draft.components[name].nodes;
	return`<div class="component-block"><h3>${labels[name]}</h3><div class="bulk-grid"><label>网段前缀<input data-bulk="prefix" data-bulk-component="${name}" placeholder="10.20.14"></label><label>起始主机号<input data-bulk="start" data-bulk-component="${name}" type="number" min="1" max="252" placeholder="41"></label><label>主机名前缀<input data-bulk="hostname" data-bulk-component="${name}" placeholder="redis-"></label><button data-preview-component="${name}" type="button">预览批量生成</button></div><div data-preview-for="${name}"></div>${nodes.map((node,index)=>`<div class="node-grid">${field(`/components/${name}/nodes/${index}/ip`,`节点 ${index+1} IPv4`,'text',node.ip)}${field(`/components/${name}/nodes/${index}/hostname`,'主机名','text',node.hostname)}<label>期望角色<select data-path="/components/${name}/nodes/${index}/role">${[...new Set(roles[name])].map(role=>`<option ${node.role===role?'selected':''}>${role}</option>`).join('')}</select></label></div>`).join('')}</div>`;
}
function showTopologyPreview(name){
	const values={};
	form.querySelectorAll(`[data-bulk-component="${name}"]`).forEach(input=>values[input.dataset.bulk]=input.value);
	const target=form.querySelector(`[data-preview-for="${name}"]`);
	try{
		const candidates=TopologyGenerator.generate(values.prefix,values.start,values.hostname);
		const rows=[];
		candidates.forEach((candidate,index)=>['ip','hostname'].forEach(key=>{
			const path=`/components/${name}/nodes/${index}/${key}`;
			const current=draft.components[name].nodes[index][key];
			const protectedField=manualTopologyPaths.has(path)||current!=='';
			rows.push(`<tr><td>节点 ${index+1} ${key==='ip'?'IPv4':'主机名'}</td><td>${escapeText(current||'（空）')}</td><td>${escapeText(candidate[key])}</td><td><input type="checkbox" data-topology-choice="${path}" data-candidate="${escapeText(candidate[key])}" ${protectedField?'':'checked'}><span>${protectedField?'保留现值':'填充空字段'}</span></td></tr>`);
		}));
		target.innerHTML=`<div class="topology-preview"><table><thead><tr><th>字段</th><th>原值</th><th>候选值</th><th>是否覆盖</th></tr></thead><tbody>${rows.join('')}</tbody></table><button data-apply-topology="${name}" type="button">应用所选字段</button></div>`;
	}catch(error){target.innerHTML=`<p class="inline-error" role="alert">${escapeText(error.message)}</p>`}
}
function render(section='management'){
	document.querySelectorAll('nav button').forEach(button=>button.classList.toggle('active',button.dataset.section===section));
	document.querySelector('#advanced').hidden=section!=='advanced';
	form.hidden=section==='advanced';
	if(section==='advanced'){editor.value=JSON.stringify(draft,null,2);return}
	if(section==='management')form.innerHTML=`<section class="form-section"><h2>管理节点与 SSH</h2><div class="field-grid">${field('/management/ip','管理节点 IPv4','text',draft.management.ip)}${field('/management/hostname','管理节点主机名','text',draft.management.hostname)}${field('/ssh/management_user','管理节点 Linux 账号','text',draft.ssh.management_user)}${field('/ssh/database_user','数据库节点 Linux 账号','text',draft.ssh.database_user)}${secretField('/secrets/management_ssh_password','管理节点 SSH 密码',draft.secrets.management_ssh_password)}${secretField('/secrets/database_ssh_password','数据库节点 SSH 密码',draft.secrets.database_ssh_password)}</div></section>`;
	if(section==='components')form.innerHTML=`<section class="form-section"><h2>部署组件</h2><div class="check-grid">${componentNames.map(name=>`<label class="check"><input data-component="${name}" type="checkbox" ${selected().includes(name)?'checked':''}>${labels[name]}</label>`).join('')}</div></section>`;
	if(section==='topology')form.innerHTML=`<section class="form-section"><h2>三节点拓扑</h2>${selected().map(topologyBlock).join('')}</section>`;
	if(section==='services')form.innerHTML=`<section class="form-section"><h2>服务参数</h2>${selected().map(name=>`<div class="component-block"><h3>${labels[name]}</h3><div class="field-grid">${serviceFields[name].map(([key,label,type])=>field(`/components/${name}/service/${key}`,label,type,draft.components[name].service[key])).join('')}</div></div>`).join('')}</section>`;
	if(section==='secrets')form.innerHTML=`<section class="form-section"><h2>组件凭据</h2>${selected().map(name=>`<div class="component-block"><h3>${labels[name]}</h3><div class="field-grid">${secretFields[name].map(([key,label])=>secretField(`/secrets/${key}`,label,draft.secrets[key]||'')).join('')}</div></div>`).join('')}</section>`;
	renderIssues(latestIssues);
}
function setPath(path,value){const parts=path.split('/').slice(1);let target=draft;parts.slice(0,-1).forEach(part=>target=target[Number.isInteger(Number(part))?Number(part):part]);const key=parts[parts.length-1];target[key]=typeof target[key]==='number'&&value!==''?Number(value):value;pendingDeployment=null;document.querySelector('#deploy').disabled=true}
async function api(path,method='GET',body,signal){const response=await fetch(path,{method,headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal});const data=await response.json();if(!response.ok){const detail=data.issues?.map(item=>`${item.path}: ${item.message}`).join('\n');throw new Error(data.error||detail||'请求失败')}return data}
async function validateDraft(signal){const current=++revision;const result=await api('/api/validate','POST',{revision:current,config:draft},signal);if(result.revision!==revision)return;statusText.textContent=result.valid?'配置有效':'需要修正';renderIssues(result.issues)}
function stopDeploymentStatusPolling(){if(deploymentStatusTimer){clearInterval(deploymentStatusTimer);deploymentStatusTimer=undefined}}
async function refreshDeploymentStatus(){if(deploymentStatusRequest)return;deploymentStatusRequest=true;try{const result=await api('/api/deploy/status');const deployment=result.deployment;if(!deployment){stopDeploymentStatusPolling();return}if(deployment.status==='running'){statusText.textContent=`部署运行中 ${deployment.generation_id}`;return}stopDeploymentStatusPolling();if(deployment.status==='succeeded'){statusText.textContent=`部署成功 ${deployment.generation_id}`;return}if(deployment.status==='failed'){statusText.textContent=`部署失败 ${deployment.generation_id}${deployment.exit_code===null?'':`（退出码 ${deployment.exit_code}）`}`;return}statusText.textContent=`部署已启动 ${deployment.generation_id}`}catch(error){stopDeploymentStatusPolling();statusText.textContent='无法读取部署状态'}finally{deploymentStatusRequest=false}}
function startDeploymentStatusPolling(){stopDeploymentStatusPolling();refreshDeploymentStatus();deploymentStatusTimer=setInterval(refreshDeploymentStatus,1000)}
function scheduleValidation(){clearTimeout(validationTimer);if(validationController)validationController.abort();validationTimer=setTimeout(async()=>{validationController=new AbortController();try{await validateDraft(validationController.signal)}catch(error){if(error.name!=='AbortError'){statusText.textContent='无法校验';issues.textContent=error.message}}},350)}
async function showWorkspace(saved){draft=saved.config||emptyDraft();pairing.hidden=true;workspace.hidden=false;render()}
async function restoreSession(){try{await showWorkspace(await api('/api/config'))}catch(error){pairing.hidden=false;workspace.hidden=true}}
form.addEventListener('input',event=>{if(event.target.dataset.path){setPath(event.target.dataset.path,event.target.value);if(event.target.dataset.path.includes('/nodes/'))manualTopologyPaths.add(event.target.dataset.path);showLocalIssue(event.target);scheduleValidation()}});
issues.addEventListener('click',event=>{const path=event.target.dataset.issuePath;if(!path)return;const section=sectionForPath(path);render(section);const control=controlForPath(path);if(control){control.focus();control.scrollIntoView({block:'center'})}});
form.addEventListener('click',async event=>{
	const generatedPath=event.target.dataset.secretGenerate;
	if(generatedPath){const name=generatedPath.split('/').pop();const notice=form.querySelector(`[data-secret-status="${generatedPath}"]`);try{const result=await api('/api/secrets/generate','POST',{name});setPath(generatedPath,result.value);const control=controlForPath(generatedPath);control.value=result.value;control.type='password';form.querySelector(`[data-secret-visibility="${generatedPath}"]`).textContent='显示';notice.textContent='已生成';scheduleValidation()}catch(error){notice.textContent='生成失败'}return}
	const visiblePath=event.target.dataset.secretVisibility;
	if(visiblePath){const control=controlForPath(visiblePath);const hidden=control.type==='password';control.type=hidden?'text':'password';event.target.textContent=hidden?'隐藏':'显示';return}
	const copyPath=event.target.dataset.secretCopy;
	if(copyPath){const notice=form.querySelector(`[data-secret-status="${copyPath}"]`);try{await navigator.clipboard.writeText(controlForPath(copyPath).value);notice.textContent='已复制'}catch(error){notice.textContent='复制失败'}return}
	const previewName=event.target.dataset.previewComponent;
	if(previewName){showTopologyPreview(previewName);return}
	const applyName=event.target.dataset.applyTopology;
	if(!applyName)return;
	form.querySelectorAll(`[data-preview-for="${applyName}"] [data-topology-choice]:checked`).forEach(input=>setPath(input.dataset.topologyChoice,input.dataset.candidate));
	render('topology');
	try{await validateDraft()}catch(error){statusText.textContent='无法校验';issues.textContent=error.message}
});
form.addEventListener('change',event=>{if(event.target.dataset.topologyChoice){event.target.nextElementSibling.textContent=event.target.checked?'覆盖现值':'保留现值';return}const name=event.target.dataset.component;if(!name)return;if(event.target.checked){draft.deployment.components.push(name);draft.components[name]=emptyComponent(name);secretFields[name].forEach(([key])=>draft.secrets[key]='')}else{draft.deployment.components=draft.deployment.components.filter(item=>item!==name);delete draft.components[name];secretFields[name].forEach(([key])=>delete draft.secrets[key])}pendingDeployment=null;document.querySelector('#deploy').disabled=true;render('components');scheduleValidation()});
document.querySelectorAll('nav button').forEach(button=>button.onclick=()=>render(button.dataset.section));
document.querySelector('#apply-json').onclick=async()=>{try{const candidate=JSON.parse(editor.value);const result=await api('/api/validate','POST',{revision:++revision,config:candidate});renderIssues(result.issues);if(!result.valid){statusText.textContent='JSON 未应用';return}draft=candidate;render('management');statusText.textContent='JSON 已应用'}catch(error){statusText.textContent='JSON 未应用';issues.textContent=error.message}};
document.querySelector('#import').onclick=()=>importFile.click();
importFile.onchange=async()=>{const file=importFile.files[0];importFile.value='';if(!file)return;if(!/\.json$/i.test(file.name)||(file.type&&file.type!=='application/json')){statusText.textContent='仅支持 JSON 文件';return}if(file.size>245760){statusText.textContent='导入文件过大';return}try{const text=await file.text();const result=await api('/api/import','POST',{config:text});renderIssues(result.issues);if(!result.valid){statusText.textContent='导入未应用';return}pendingImport=JSON.parse(text);const summary=result.summary;const details=`版本 ${summary.schema_version}；组件 ${summary.components.join('、')}；管理节点 ${summary.management.hostname} (${summary.management.ip})`;
if(!confirm(`将替换当前内存草稿。\n${details}`)){pendingImport=null;statusText.textContent='已取消导入';return}draft=pendingImport;pendingImport=null;render('management');statusText.textContent='JSON 已导入'}catch(error){pendingImport=null;statusText.textContent='导入未应用';issues.textContent=error.message}};
document.querySelector('#export').onclick=async()=>{try{const result=await api('/api/export','POST',{config:draft});const blob=new Blob([JSON.stringify(result.config,null,2)+'\n'],{type:'application/json'});const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download='ecopilot-config-template.json';link.click();URL.revokeObjectURL(link.href);statusText.textContent='已导出脱敏 JSON'}catch(error){statusText.textContent='导出失败';issues.textContent=error.message}};
document.querySelector('#pair').onclick=async()=>{try{await api('/api/pair','POST',{code:document.querySelector('#pair-code').value});document.querySelector('#pair-code').value='';await showWorkspace(await api('/api/config'))}catch(error){document.querySelector('#pair-error').textContent=error.message}};
document.querySelector('#validate').onclick=async()=>{clearTimeout(validationTimer);if(validationController)validationController.abort();try{await validateDraft()}catch(error){statusText.textContent='无法校验';issues.textContent=error.message}};
document.querySelector('#save').onclick=async()=>{try{const result=await api('/api/config','PUT',{config:draft});statusText.textContent=result.valid?'草稿已保存':'需要修正';renderIssues(result.issues)}catch(error){statusText.textContent='未保存';issues.textContent=error.message}};
document.querySelector('#preflight').onclick=async()=>{const warning='首次 SSH 连接会使用当前已批准的 StrictHostKeyChecking=no 策略，存在主机指纹被伪造或中间人攻击风险。仅对本配置中的主机发起 TCP 22、SSH、sudo、平台和端口检查。确认继续？';if(!confirm(warning))return;try{const result=await api('/api/preflight','POST',{config:draft,fingerprint_risk_acknowledged:true});const target=document.querySelector('#preflight-results');target.replaceChildren();const list=document.createElement('ul');result.results.forEach(item=>{const entry=document.createElement('li');entry.textContent=`${item.node_id} | ${item.check} | ${item.status} | ${item.code}${item.advice?` | ${item.advice}`:''}`;list.appendChild(entry)});target.appendChild(list);statusText.textContent=result.results.some(item=>item.status==='fail')?'连接预检失败':'连接预检完成'}catch(error){statusText.textContent='连接预检未完成';issues.textContent=error.message}};
document.querySelector('#generate').onclick=async()=>{try{pendingDeployment=await api('/api/generate','POST',{config:draft});document.querySelector('#deploy').disabled=false;statusText.textContent=`已生成 ${pendingDeployment.generation_id}`}catch(error){pendingDeployment=null;document.querySelector('#deploy').disabled=true;statusText.textContent='生成失败';issues.textContent=error.message}};
document.querySelector('#deploy').onclick=async()=>{if(!pendingDeployment)return;const plan=pendingDeployment.plan;const details=`组件 ${plan.components.map(item=>item.name).join('、')}；管理节点 ${plan.management.hostname} (${plan.management.ip})`;if(!confirm(`将按以下计划启动部署。\n${details}`))return;try{const result=await api('/api/deploy','POST',{generation_id:pendingDeployment.generation_id,confirmation_token:pendingDeployment.confirmation_token,request_id:crypto.randomUUID()});pendingDeployment=null;document.querySelector('#deploy').disabled=true;statusText.textContent=`部署运行中 ${result.generation_id}`;startDeploymentStatusPolling()}catch(error){statusText.textContent='部署未启动';issues.textContent=error.message}};
document.querySelector('#shutdown').onclick=async()=>{try{stopDeploymentStatusPolling();await api('/api/shutdown','POST',{});draft=null;editor.value='';form.replaceChildren();document.body.textContent='工作台已关闭'}catch(error){issues.textContent=error.message}};
restoreSession();