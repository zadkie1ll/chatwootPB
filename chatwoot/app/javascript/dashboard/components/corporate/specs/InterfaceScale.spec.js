import { mount } from '@vue/test-utils';
import { defineComponent, ref, nextTick } from 'vue';
import InterfaceScale from '../InterfaceScale.vue';
import {
  useInterfaceScaleDOM,
  interfaceCoordinate,
} from 'dashboard/composables/useInterfaceScale';

const settings = ref({});
const update = vi.fn(value => {
  settings.value = { ...settings.value, ...value };
});
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: settings, updateUISettings: update }),
}));
const Host = defineComponent({
  components: { InterfaceScale },
  setup() {
    useInterfaceScaleDOM();
  },
  template: '<InterfaceScale />',
});

describe('Corporate interface scale', () => {
  let wrapper;
  beforeEach(() => {
    settings.value = {};
    update.mockClear();
    window.chatwootConfig = { corporateAccessEnabled: true };
  });
  afterEach(() => {
    wrapper?.unmount();
  });
  it('offers the four scales and saves the selection as a personal UI setting', async () => {
    wrapper = mount(Host);
    expect(wrapper.findAll('option').map(option => option.text())).toEqual([
      '65%',
      '85%',
      '100%',
      '120%',
    ]);
    await wrapper.find('select').setValue('85');
    expect(update).toHaveBeenCalledWith({ corporate_interface_scale: 85 });
    expect(document.documentElement.classList.contains('[zoom:0.85]')).toBe(
      true
    );
    expect(interfaceCoordinate(85)).toBe(100);
    await wrapper.find('select').setValue('120');
    expect(document.documentElement.classList.contains('[zoom:0.85]')).toBe(
      false
    );
    expect(interfaceCoordinate(120)).toBe(100);
  });
  it('restores a saved scale and removes zoom when the dashboard is left', async () => {
    settings.value = { corporate_interface_scale: 65 };
    wrapper = mount(Host);
    expect(wrapper.find('select').element.value).toBe('65');
    expect(document.documentElement.dataset.interfaceScale).toBe('0.65');
    wrapper.unmount();
    expect(interfaceCoordinate(65)).toBe(65);
    expect(document.documentElement.classList.contains('[zoom:0.65]')).toBe(
      false
    );
  });
  it('uses 100 percent for an unsupported stored value', async () => {
    settings.value = { corporate_interface_scale: 0 };
    wrapper = mount(Host);
    expect(wrapper.find('select').element.value).toBe('100');
    settings.value = { corporate_interface_scale: 85 };
    await nextTick();
    expect(wrapper.find('select').element.value).toBe('85');
  });
});
