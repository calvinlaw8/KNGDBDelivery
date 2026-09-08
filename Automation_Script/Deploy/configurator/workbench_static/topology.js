(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.TopologyGenerator = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  function generate(prefix, startValue, hostnamePrefix) {
    const octets = String(prefix).replace(/\.$/, '').split('.');
    if (octets.length !== 3 || octets.some(function (part) {
      return !/^\d{1,3}$/.test(part) || Number(part) > 255;
    })) throw new Error('网段前缀必须是三个合法 IPv4 八位组');

    const start = Number(startValue);
    if (!Number.isInteger(start) || start < 1 || start + 2 > 254) {
      throw new Error('起始主机号必须为 1 到 252，且三节点不能越过 .254');
    }
    if (!hostnamePrefix) throw new Error('主机名前缀不能为空');

    return [0, 1, 2].map(function (offset) {
      const hostname = String(hostnamePrefix) + (offset + 1);
      if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(hostname)) {
        throw new Error('主机名前缀生成了非法主机名');
      }
      return {ip: octets.join('.') + '.' + (start + offset), hostname: hostname};
    });
  }

  return {generate: generate};
}));