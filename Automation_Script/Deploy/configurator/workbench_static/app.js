const pairing=document.querySelector('#pairing');
const workspace=document.querySelector('#workspace');
const editor=document.querySelector('#config');
const form=document.querySelector('#form');
const issues=document.querySelector('#issues');
const statusText=document.querySelector('#status');
const workflowResult=document.querySelector('#workflow-result');
const workflowTitle=document.querySelector('#workflow-title');
const workflowDetail=document.querySelector('#workflow-detail');
const workflowDeploy=document.querySelector('#workflow-deploy');
const workflowCancel=document.querySelector('#workflow-cancel');
const workflowRefreshPlaybooks=document.querySelector('#workflow-refresh-playbooks');
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
let latestIssues=null;
let pendingImport;
let pendingDeployment;
let deploymentRequestId;
let deploymentStatusTimer;
let deploymentStatusRequest=false;
let configValid=false;
let preflightPassed=false;
let preflightRunning=false;
const manualTopologyPaths=new Set();

function emptyDraft(){return{schema_version:1,deployment:{components:['redis'],rabbitmq_rebuild_cluster:false},management:{ip:'',hostname:''},ssh:{management_user:'sysadmin',database_user:'sysadmin'},components:{redis:emptyComponent('redis')},secrets:{management_ssh_password:'',database_ssh_password:'',redis_password:''}}}
function emptyComponent(name){const service={};serviceFields[name].forEach(([key,,,value])=>service[key]=value);return{nodes:roles[name].map(role=>({ip:'',hostname:'',role})),service}}
function escapeText(value){return String(value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function setWorkflow(title,detail,tone=''){workflowTitle.textContent=title;workflowDetail.textContent=detail;workflowResult.dataset.tone=tone}
function updateActionAvailability(){
	document.querySelector('#preflight').disabled=!configValid||preflightRunning;
	document.querySelector('#generate').disabled=!configValid||!preflightPassed;
	document.querySelector('#deploy').disabled=!pendingDeployment;
}
function resetDeploymentStages(){
	preflightPassed=false;
	pendingDeployment=null;
	deploymentRequestId=undefined;
	workflowDeploy.hidden=true;
	workflowRefreshPlaybooks.hidden=true;
	updateActionAvailability();
}
function nodeLabel(nodeId){if(nodeId==='local')return'本机';if(nodeId==='management')return'管理节点';const match=/^(redis|rabbitmq|mongodb|mysql)-(\d+)$/.exec(nodeId);return match?`${labels[match[1]]} 节点 ${match[2]}`:nodeId}
function checkLabel(check){return{dependencies:'本机依赖',tcp_22:'SSH 端口连通性',ssh:'SSH 登录',sudo:'免密 sudo',platform:'系统平台',ports:'服务端口',preflight:'预检时限'}[check]||check}
function stateLabel(status){return{pass:'通过',fail:'失败',warning:'需确认'}[status]||status}
function issuePathLabel(path){const direct={'/management/ip':'管理节点 IPv4','/management/hostname':'管理节点主机名','/ssh/management_user':'管理节点系统账号','/ssh/database_user':'数据库节点系统账号','/secrets/management_ssh_password':'管理节点 SSH 密码','/secrets/database_ssh_password':'数据库节点 SSH 密码','/secrets/redis_password':'Redis 密码'};if(direct[path])return direct[path];const node=/^\/components\/(redis|rabbitmq|mongodb|mysql)\/nodes\/(\d+)\/(ip|hostname|role)$/.exec(path);return node?`${labels[node[1]]} 节点 ${Number(node[2])+1} ${node[3]==='ip'?'IPv4':node[3]==='hostname'?'主机名':'角色'}`:path}
function issueMessage(message){return{'invalid IPv4 address':'请输入有效的 IPv4 地址','invalid hostname':'请输入有效的主机名','value must not be empty':'此字段不能为空'}[message]||message}
function displayError(error){return{'a successful preflight is required before generation':'当前配置尚未通过连接预检；配置变更后也需要重新预检。'}[error.message]||error.message}
function fieldId(path){return'field-'+path.replace(/[^a-zA-Z0-9]+/g,'-').replace(/^-|-$/g,'')}
function field(path,label,type='text',value=''){const id=fieldId(path);return`<label for="${id}">${label}<input id="${id}" data-path="${path}" type="${type}" value="${escapeText(value)}" ${type==='password'?'autocomplete="new-password"':''}></label>`}
function secretField(path,label,value=''){const id=fieldId(path);return`<label for="${id}">${label}<span class=\"secret-control\"><input id="${id}" data-path=\"${path}\" type=\"password\" value=\"${escapeText(value)}\" autocomplete=\"new-password\"><span class=\"secret-actions\"><button data-secret-generate=\"${path}\" type=\"button\">生成</button><button data-secret-visibility=\"${path}\" type=\"button\">显示</button><button data-secret-copy=\"${path}\" type=\"button\">复制</button></span></span><span class=\"secret-status\" data-secret-status=\"${path}\" aria-live=\"polite\"></span></label>`}
function selected(){return draft.deployment.components}
function sectionForPath(path){if(path.indexOf('/components/')===0)return path.indexOf('/nodes/')>0?'topology':'services';if(path.indexOf('/deployment/')===0)return'components';if(path.indexOf('/secrets/')===0)return path==='/secrets/management_ssh_password'||path==='/secrets/database_ssh_password'?'management':'secrets';return'management'}
function controlForPath(path){return Array.from(form.querySelectorAll('[data-path]')).find(control=>control.dataset.path===path)}
function clearFieldIssues(){form.querySelectorAll('.field-error').forEach(error=>error.remove());form.querySelectorAll('[aria-invalid="true"]').forEach(control=>{control.removeAttribute('aria-invalid');control.removeAttribute('aria-describedby')})}
function renderIssues(items){
	latestIssues=items;
	clearFieldIssues();
	issues.replaceChildren();
	issues.id='issues';
	issues.tabIndex=-1;
	issues.setAttribute('role',items&&items.some(item=>item.severity==='error')?'alert':'status');
	const validated=Array.isArray(items);
	configValid=validated&&!items.some(item=>item.severity==='error');
	updateActionAvailability();
	if(!validated){issues.textContent='请先填写部署配置，然后执行校验。';return}
	if(!items.length){issues.textContent='未发现问题';return}
	const list=document.createElement('ul');
	items.forEach((item,index)=>{
		const entry=document.createElement('li');
		const link=document.createElement('button');
		link.type='button';link.className=`issue-link ${item.severity}`;link.dataset.issuePath=item.path;link.textContent=`${item.severity==='error'?'需修正':'提示'}：${issuePathLabel(item.path)}：${issueMessage(item.message)}`;entry.appendChild(link);list.appendChild(entry);
		if(item.severity!=='error')return;
		const control=controlForPath(item.path);
		if(!control)return;
		const error=document.createElement('span');
		error.className='field-error';error.id=`field-error-${index}`;error.textContent=issueMessage(item.message);control.setAttribute('aria-invalid','true');control.setAttribute('aria-describedby',error.id);control.closest('label').appendChild(error);
	});
	issues.appendChild(list);
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
	document.querySelectorAll('nav button').forEach(button=>{
		const active=button.dataset.section===section;
		button.classList.toggle('active',active);
		if(active)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');
	});
	document.querySelector('#advanced').hidden=section!=='advanced';
	form.hidden=section==='advanced';
	if(section==='advanced'){editor.value=JSON.stringify(draft,null,2);return}
	if(section==='management')form.innerHTML=`<section class="form-section"><h2>管理节点与 SSH</h2><div class="field-grid">${field('/management/ip','管理节点 IPv4','text',draft.management.ip)}${field('/management/hostname','管理节点主机名','text',draft.management.hostname)}${field('/ssh/management_user','管理节点 Linux 账号','text',draft.ssh.management_user)}${field('/ssh/database_user','数据库节点 Linux 账号','text',draft.ssh.database_user)}${secretField('/secrets/management_ssh_password','管理节点 SSH 密码',draft.secrets.management_ssh_password)}${secretField('/secrets/database_ssh_password','数据库节点 SSH 密码',draft.secrets.database_ssh_password)}</div></section>`;
	if(section==='components')form.innerHTML=`<section class="form-section"><h2>部署组件</h2><div class="check-grid">${componentNames.map(name=>`<label class="check"><input data-component="${name}" type="checkbox" ${selected().includes(name)?'checked':''}>${labels[name]}</label>`).join('')}</div>${selected().includes('rabbitmq')?`<label class="check danger-option"><input data-path="/deployment/rabbitmq_rebuild_cluster" type="checkbox" ${draft.deployment.rabbitmq_rebuild_cluster?'checked':''}>重建 RabbitMQ 集群（清空节点状态）</label><p class="field-help">仅用于无业务数据的首次部署。执行前会备份现有状态，但会删除 RabbitMQ 队列、消息、用户和集群元数据。</p>`:''}</section>`;
	if(section==='topology')form.innerHTML=`<section class="form-section"><h2>三节点拓扑</h2>${selected().map(topologyBlock).join('')}</section>`;
	if(section==='services')form.innerHTML=`<section class="form-section"><h2>服务参数</h2>${selected().map(name=>`<div class="component-block"><h3>${labels[name]}</h3><div class="field-grid">${serviceFields[name].map(([key,label,type])=>field(`/components/${name}/service/${key}`,label,type,draft.components[name].service[key])).join('')}</div></div>`).join('')}</section>`;
	if(section==='secrets')form.innerHTML=`<section class="form-section"><h2>组件凭据</h2>${selected().map(name=>`<div class="component-block"><h3>${labels[name]}</h3><div class="field-grid">${secretFields[name].map(([key,label])=>secretField(`/secrets/${key}`,label,draft.secrets[key]||'')).join('')}</div></div>`).join('')}</section>`;
	renderIssues(latestIssues);
}
function setPath(path,value){const parts=path.split('/').slice(1);let target=draft;parts.slice(0,-1).forEach(part=>target=target[Number.isInteger(Number(part))?Number(part):part]);const key=parts[parts.length-1];target[key]=typeof target[key]==='number'&&value!==''?Number(value):value;configValid=false;resetDeploymentStages();setWorkflow('配置已变更','请重新校验并完成连接预检，然后生成配置；生成成功后才能开始部署。','warning')}
async function api(path,method='GET',body,signal){const response=await fetch(path,{method,headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal});const data=await response.json();if(!response.ok){const detail=data.issues?.map(item=>`${item.path}: ${item.message}`).join('\n');throw new Error(data.error||detail||'请求失败')}return data}
async function validateDraft(signal,moveFocus=false){const current=++revision;const result=await api('/api/validate','POST',{revision:current,config:draft},signal);if(result.revision!==revision)return;statusText.textContent=result.valid?'配置校验通过':'配置需要修正';renderIssues(result.issues);if(moveFocus&&result.issues.some(item=>item.severity==='error')){issues.focus();issues.scrollIntoView({block:'center'})}if(result.valid)setWorkflow('配置校验通过','下一步可执行连接预检。')}
function stopDeploymentStatusPolling(){if(deploymentStatusTimer){clearInterval(deploymentStatusTimer);deploymentStatusTimer=undefined}}
async function refreshDeploymentStatus(){if(deploymentStatusRequest)return;deploymentStatusRequest=true;try{const result=await api('/api/deploy/status');const deployment=result.deployment;if(!deployment){stopDeploymentStatusPolling();workflowCancel.hidden=true;return}if(deployment.status==='running'){workflowCancel.hidden=false;workflowCancel.disabled=false;statusText.textContent=`部署运行中 ${deployment.generation_id}`;setWorkflow('部署运行中',`部署批次 ${deployment.generation_id} 正在执行，可请求停止本地部署进程。`);return}if(deployment.status==='stop_requested'){workflowCancel.hidden=false;workflowCancel.disabled=true;statusText.textContent=`正在取消部署 ${deployment.generation_id}`;setWorkflow('正在取消部署',`已请求停止部署批次 ${deployment.generation_id}，正在等待本地进程退出。`,'warning');return}stopDeploymentStatusPolling();workflowDeploy.hidden=true;workflowCancel.hidden=true;if(deployment.status==='succeeded'){statusText.textContent=`部署成功 ${deployment.generation_id}`;setWorkflow('部署成功',`部署批次 ${deployment.generation_id} 已完成。`,'ready');return}if(deployment.status==='failed'){const exitCode=deployment.exit_code===null?'':`（退出码 ${deployment.exit_code}）`;statusText.textContent=`部署失败 ${deployment.generation_id}${exitCode}`;setWorkflow('部署失败',`部署批次 ${deployment.generation_id}${exitCode}。请查看终端部署日志，修复原因后重新生成配置。`,'error');return}if(deployment.status==='cancelled'){statusText.textContent=`部署已取消 ${deployment.generation_id}`;setWorkflow('部署已取消',`部署批次 ${deployment.generation_id} 的本地进程已退出；远端状态仍需按日志确认。`,'warning');return}if(deployment.status==='remote_state_unknown'){statusText.textContent=`部署状态未知 ${deployment.generation_id}`;setWorkflow('部署状态未知','本地进程组无法确认停止，远端状态不能视为成功或失败。请查看部署日志并人工核验。','error');return}statusText.textContent=`部署已启动 ${deployment.generation_id}`;setWorkflow('部署已启动',`部署批次 ${deployment.generation_id} 已提交，正在等待执行。`)}catch(error){stopDeploymentStatusPolling();workflowCancel.hidden=true;statusText.textContent='无法读取部署状态';setWorkflow('无法读取部署状态','无法获取部署进度，请查看终端日志。','error')}finally{deploymentStatusRequest=false}}
function startDeploymentStatusPolling(){stopDeploymentStatusPolling();refreshDeploymentStatus();deploymentStatusTimer=setInterval(refreshDeploymentStatus,1000)}
function scheduleValidation(){clearTimeout(validationTimer);if(validationController)validationController.abort();validationTimer=setTimeout(async()=>{validationController=new AbortController();try{await validateDraft(validationController.signal)}catch(error){if(error.name!=='AbortError'){statusText.textContent='无法校验';issues.textContent=error.message}}},350)}
async function showWorkspace(saved){draft=saved.config||emptyDraft();configValid=false;resetDeploymentStages();pairing.hidden=true;workspace.hidden=false;render()}
async function restoreSession(){try{await showWorkspace(await api('/api/config'))}catch(error){pairing.hidden=false;workspace.hidden=true}}
form.addEventListener('input',event=>{if(event.target.dataset.path){const value=event.target.type==='checkbox'?event.target.checked:event.target.value;setPath(event.target.dataset.path,value);if(event.target.dataset.path.includes('/nodes/'))manualTopologyPaths.add(event.target.dataset.path);showLocalIssue(event.target);if(event.target.type!=='checkbox')scheduleValidation()}});
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
form.addEventListener('change',event=>{if(event.target.dataset.topologyChoice){event.target.nextElementSibling.textContent=event.target.checked?'覆盖现值':'保留现值';return}if(event.target.dataset.path==='/deployment/rabbitmq_rebuild_cluster'){if(event.target.checked&&!confirm('危险操作：这会重置三个 RabbitMQ 节点并清空队列、消息、用户和集群元数据。仅确认无须保留现有 RabbitMQ 数据时继续.')){event.target.checked=false;return}draft.deployment.rabbitmq_rebuild_cluster=event.target.checked;configValid=false;resetDeploymentStages();render('components');scheduleValidation();return}const name=event.target.dataset.component;if(!name)return;if(event.target.checked){draft.deployment.components.push(name);draft.components[name]=emptyComponent(name);secretFields[name].forEach(([key])=>draft.secrets[key]='')}else{draft.deployment.components=draft.deployment.components.filter(item=>item!==name);delete draft.components[name];secretFields[name].forEach(([key])=>delete draft.secrets[key])}configValid=false;resetDeploymentStages();render('components');scheduleValidation()});
document.querySelectorAll('nav button').forEach(button=>button.onclick=()=>render(button.dataset.section));
document.querySelector('#apply-json').onclick=async()=>{try{const candidate=JSON.parse(editor.value);const result=await api('/api/validate','POST',{revision:++revision,config:candidate});renderIssues(result.issues);if(!result.valid){statusText.textContent='JSON 未应用';return}draft=candidate;preflightPassed=false;pendingDeployment=null;render('management');statusText.textContent='JSON 已应用'}catch(error){statusText.textContent='JSON 未应用';issues.textContent=error.message}};
document.querySelector('#restore-current').onclick=async()=>{if(!confirm('将把已发布 current generation 的完整配置恢复到当前内存草稿。不会启动预检或部署；恢复后仍需校验、确认 SSH 指纹风险并按顺序完成所有阶段。确认继续？'))return;try{const result=await api('/api/current/restore','POST',{});draft=result.config;configValid=false;preflightPassed=false;pendingDeployment=null;render('management');statusText.textContent=`已恢复 current generation ${result.generation_id}`;setWorkflow('当前配置已恢复','请先校验配置；RabbitMQ 重建必须在部署组件中明确勾选并再次确认。','warning')}catch(error){statusText.textContent='当前配置恢复失败';setWorkflow('当前配置恢复失败',displayError(error),'error');issues.textContent=displayError(error)}};
document.querySelector('#import').onclick=()=>importFile.click();
document.querySelector('#preflight-current').onclick=async()=>{if(preflightRunning)return;const warning='当前已发布部署配置将执行 SSH 主机指纹风险提示、TCP 22、SSH、sudo、平台和端口检查。首次 SSH 连接使用 StrictHostKeyChecking=no。确认继续？';if(!confirm(warning))return;preflightRunning=true;updateActionAvailability();statusText.textContent='当前部署配置预检进行中';setWorkflow('当前部署配置预检进行中','正在检查已发布 generation 的目标主机，请稍候……');try{const result=await api('/api/current/preflight','POST',{fingerprint_risk_acknowledged:true});const target=document.querySelector('#preflight-results');target.replaceChildren();const failed=result.results.filter(item=>item.status==='fail');const summary=document.createElement('p');summary.className='preflight-summary';summary.textContent=result.passed?`当前部署配置预检通过：${result.results.length} 项检查完成。`:`当前部署配置预检未通过：${failed.length} 项失败。`;target.appendChild(summary);if(!result.passed){const list=document.createElement('ul');list.className='preflight-results';failed.forEach(item=>{const entry=document.createElement('li');entry.textContent=`${nodeLabel(item.node_id)}：${checkLabel(item.check)} ${stateLabel(item.status)}${item.advice?`。${item.advice}`:''}`;list.appendChild(entry)});target.appendChild(list);statusText.textContent='当前部署配置预检未通过';setWorkflow('当前部署配置预检未通过','请根据下方失败项修正目标主机后重新预检。','error');return}pendingDeployment=await api('/api/current/deploy/prepare','POST',{});workflowDeploy.hidden=false;workflowRefreshPlaybooks.hidden=false;statusText.textContent='当前部署配置预检通过';setWorkflow('当前部署配置预检通过','已取得现有部署计划。确认部署，或先发布已修复剧本后重新预检。','ready')}catch(error){pendingDeployment=null;statusText.textContent='当前部署配置预检未完成';setWorkflow('当前部署配置预检未完成',displayError(error),'error');issues.textContent=displayError(error)}finally{preflightRunning=false;updateActionAvailability()}};
importFile.onchange=async()=>{const file=importFile.files[0];importFile.value='';if(!file)return;if(!/\.json$/i.test(file.name)||(file.type&&file.type!=='application/json')){statusText.textContent='仅支持 JSON 文件';return}if(file.size>245760){statusText.textContent='导入文件过大';return}try{const text=await file.text();const result=await api('/api/import','POST',{config:text});renderIssues(result.issues);if(!result.valid){statusText.textContent='导入未应用';return}pendingImport=JSON.parse(text);const summary=result.summary;const details=`版本 ${summary.schema_version}；组件 ${summary.components.join('、')}；管理节点 ${summary.management.hostname} (${summary.management.ip})`;
if(!confirm(`将替换当前内存草稿。\n${details}`)){pendingImport=null;statusText.textContent='已取消导入';return}draft=pendingImport;pendingImport=null;preflightPassed=false;pendingDeployment=null;render('management');statusText.textContent='JSON 已导入'}catch(error){pendingImport=null;statusText.textContent='导入未应用';issues.textContent=error.message}};
document.querySelector('#export').onclick=async()=>{try{const result=await api('/api/export','POST',{config:draft});const blob=new Blob([JSON.stringify(result.config,null,2)+'\n'],{type:'application/json'});const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download='ecopilot-config-template.json';link.click();URL.revokeObjectURL(link.href);statusText.textContent='已导出脱敏 JSON'}catch(error){statusText.textContent='导出失败';issues.textContent=error.message}};
document.querySelector('#pair').onclick=async()=>{try{await api('/api/pair','POST',{code:document.querySelector('#pair-code').value});document.querySelector('#pair-code').value='';await showWorkspace(await api('/api/config'))}catch(error){document.querySelector('#pair-error').textContent=error.message}};
document.querySelector('#validate').onclick=async()=>{clearTimeout(validationTimer);if(validationController)validationController.abort();try{await validateDraft(undefined,true)}catch(error){statusText.textContent='无法校验';issues.textContent=error.message}};
document.querySelector('#save').onclick=async()=>{try{const result=await api('/api/config','PUT',{config:draft});statusText.textContent=result.valid?'草稿已保存':'需要修正';renderIssues(result.issues)}catch(error){statusText.textContent='未保存';issues.textContent=error.message}};
document.querySelector('#preflight').onclick=async()=>{if(!configValid||preflightRunning)return;const warning='首次 SSH 连接会使用当前已批准的 StrictHostKeyChecking=no 策略，存在主机指纹被伪造或中间人攻击风险。仅对本配置中的主机发起 TCP 22、SSH、sudo、平台和端口检查。确认继续？';if(!confirm(warning))return;preflightRunning=true;updateActionAvailability();statusText.textContent='连接预检进行中';setWorkflow('连接预检进行中','正在检查 SSH、sudo、系统平台和服务端口，请稍候……');try{const result=await api('/api/preflight','POST',{config:draft,fingerprint_risk_acknowledged:true});preflightPassed=result.passed;pendingDeployment=null;const target=document.querySelector('#preflight-results');target.replaceChildren();const failed=result.results.filter(item=>item.status==='fail');const warnings=result.results.filter(item=>item.status==='warning');const summary=document.createElement('p');summary.className='preflight-summary';summary.textContent=!result.passed?`连接预检未通过：${failed.length} 项失败。修正后请重新预检。`:warnings.length?`连接预检通过：${result.results.length} 项检查完成，另有 ${warnings.length} 项需确认。`:`连接预检通过：${result.results.length} 项检查全部通过。`;target.appendChild(summary);const list=document.createElement('ul');list.className='preflight-results';result.results.forEach(item=>{const entry=document.createElement('li');entry.textContent=`${nodeLabel(item.node_id)}：${checkLabel(item.check)} ${stateLabel(item.status)}${item.advice?`。${item.advice}`:''}`;list.appendChild(entry)});target.appendChild(list);if(!result.passed){statusText.textContent='连接预检未通过';setWorkflow('连接预检未通过','请根据下方失败项修正配置或目标主机，然后重新执行预检。','error')}else{statusText.textContent='连接预检通过';setWorkflow('连接预检通过',warnings.length?'可生成配置；请同时确认下方标记为“需确认”的项目。':'现在可以生成配置。','ready')}}catch(error){preflightPassed=false;pendingDeployment=null;statusText.textContent='连接预检未完成';setWorkflow('连接预检未完成',displayError(error),'error');issues.textContent=displayError(error)}finally{preflightRunning=false;updateActionAvailability()}};
document.querySelector('#generate').onclick=async()=>{if(!configValid||!preflightPassed)return;try{pendingDeployment=await api('/api/generate','POST',{config:draft});updateActionAvailability();workflowDeploy.hidden=false;statusText.textContent='配置生成成功';setWorkflow('配置生成成功','已生成可部署配置。请确认本次部署计划后，点击上方按钮开始部署。','ready')}catch(error){pendingDeployment=null;workflowDeploy.hidden=true;updateActionAvailability();statusText.textContent='配置生成失败';setWorkflow('配置生成失败',displayError(error),'error');issues.textContent=displayError(error)}};
document.querySelector('#deploy').onclick=async()=>{if(!pendingDeployment)return;const plan=pendingDeployment.plan;const details=`组件 ${plan.components.map(item=>item.name).join('、')}；管理节点 ${plan.management.hostname} (${plan.management.ip})`;if(!confirm(`将按以下计划启动部署。\n${details}`))return;workflowDeploy.hidden=true;try{deploymentRequestId=crypto.randomUUID();const result=await api('/api/deploy','POST',{generation_id:pendingDeployment.generation_id,confirmation_token:pendingDeployment.confirmation_token,request_id:deploymentRequestId});pendingDeployment=null;document.querySelector('#deploy').disabled=true;statusText.textContent=`部署运行中 ${result.generation_id}`;setWorkflow('部署运行中',`部署批次 ${result.generation_id} 正在执行，请等待终态。`);startDeploymentStatusPolling()}catch(error){deploymentRequestId=undefined;statusText.textContent='部署未启动';setWorkflow('部署未启动',error.message,'error');issues.textContent=error.message}};
workflowCancel.onclick=async()=>{if(!deploymentRequestId||workflowCancel.disabled)return;if(!confirm('将请求停止本地部署进程。远端 Ansible 已执行的操作无法自动回滚，确认继续？'))return;workflowCancel.disabled=true;try{await api('/api/deploy/cancel','POST',{request_id:deploymentRequestId});statusText.textContent='已请求取消部署';setWorkflow('正在取消部署','已请求停止本地部署进程，正在等待状态确认。','warning');startDeploymentStatusPolling()}catch(error){workflowCancel.disabled=false;statusText.textContent='取消请求未完成';setWorkflow('取消请求未完成',error.message,'error');issues.textContent=error.message}};
workflowDeploy.onclick=()=>{document.querySelector('#deploy').scrollIntoView({behavior:'smooth',block:'center'});document.querySelector('#deploy').click()};
workflowRefreshPlaybooks.onclick=async()=>{if(!confirm('将创建新的不可变部署配置：保留当前已发布配置字节，仅替换工作区已修复的 Playbook。发布后必须重新执行网页预检并再次确认部署。确认继续？'))return;try{const result=await api('/api/current/refresh-playbooks','POST',{});pendingDeployment=null;workflowDeploy.hidden=true;workflowRefreshPlaybooks.hidden=true;statusText.textContent=`已发布已修复剧本 ${result.generation_id}`;setWorkflow('已发布已修复剧本','已创建新的不可变 generation。请重新执行当前部署配置预检。','ready')}catch(error){setWorkflow('剧本发布失败',displayError(error),'error');issues.textContent=displayError(error)}};
document.querySelector('#shutdown').onclick=async()=>{try{stopDeploymentStatusPolling();await api('/api/shutdown','POST',{});draft=null;editor.value='';form.replaceChildren();document.body.textContent='工作台已关闭'}catch(error){issues.textContent=error.message}};
document.querySelector('#config-form').addEventListener('submit',event=>event.preventDefault());
restoreSession();