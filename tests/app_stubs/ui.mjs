// A ui stub: attachMenu keeps the items function of each button.
export const menus = {};
export const h = () => ({ append() {}, addEventListener() {} });
export const announce = () => {};
export const attachMenu = (button, items) => { menus[button.id] = items; };
export const closeMenu = () => {};
export const alertBox = () => {};
export const confirmBox = async () => null;
export const segmented = () => ({});
export const download = () => {};
export const pickFile = async () => [];
export const copyText = async () => {};
export const isMac = false;
export const cmdKey = "Ctrl+";
