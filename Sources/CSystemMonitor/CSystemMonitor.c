#include "CSystemMonitor.h"
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdio.h>

static double mach_seconds(uint64_t ticks) {
    mach_timebase_info_data_t scale = {0, 0};
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return 0;
    return (double)ticks * (double)scale.numer / (double)scale.denom / 1000000000.0;
}

int32_t ms_list_pids(int32_t *buffer, int32_t capacity) {
    if (!buffer || capacity <= 0) return 0;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, capacity * (int32_t)sizeof(int32_t));
    return bytes > 0 ? bytes / (int32_t)sizeof(int32_t) : 0;
}

int32_t ms_read_process(int32_t pid, MSProcessSample *result) {
    if (!result || pid <= 0) return 0;
    memset(result, 0, sizeof(*result));
    result->pid = pid;
    struct rusage_info_v6 info6 = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&info6) == 0) {
        result->start_time = info6.ri_proc_start_abstime;
        result->cpu_seconds = mach_seconds(info6.ri_user_time + info6.ri_system_time);
        result->performance_cpu_seconds = mach_seconds(info6.ri_user_ptime + info6.ri_system_ptime);
        result->physical_bytes = info6.ri_phys_footprint;
        result->read_bytes = info6.ri_diskio_bytesread;
        result->written_bytes = info6.ri_diskio_byteswritten;
        result->cpu_energy_joules = (double)info6.ri_energy_nj / 1000000000.0;
        result->has_performance_time = 1;
        result->has_energy = info6.ri_energy_nj > 0;
    } else {
        struct rusage_info_v2 info2 = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info2) != 0) return 0;
        result->start_time = info2.ri_proc_start_abstime;
        result->cpu_seconds = mach_seconds(info2.ri_user_time + info2.ri_system_time);
        result->physical_bytes = info2.ri_phys_footprint;
        result->read_bytes = info2.ri_diskio_bytesread;
        result->written_bytes = info2.ri_diskio_byteswritten;
    }
    proc_pidpath(pid, result->path, sizeof(result->path));
    return 1;
}

int32_t ms_read_system(MSSystemSample *result) {
    if (!result) return 0;
    memset(result, 0, sizeof(*result));
    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) != KERN_SUCCESS) return 0;
    result->busy_ticks = (uint64_t)cpu.cpu_ticks[CPU_STATE_USER] + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
    result->total_ticks = result->busy_ticks + cpu.cpu_ticks[CPU_STATE_IDLE];
    uint64_t memory = 0;
    size_t memory_size = sizeof(memory);
    if (sysctlbyname("hw.memsize", &memory, &memory_size, NULL, 0) == 0) result->physical_bytes = memory;
    vm_statistics64_data_t vm = {0};
    count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        uint64_t available = ((uint64_t)vm.free_count + vm.inactive_count + vm.speculative_count) * (uint64_t)vm_kernel_page_size;
        result->used_bytes = available < memory ? memory - available : 0;
    }
    return 1;
}

int32_t ms_read_battery(MSBatterySample *result) {
    if (!result) return 0;
    memset(result, 0, sizeof(*result));
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return 0;
    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) { CFRelease(blob); return 0; }
    for (CFIndex i = 0; i < CFArrayGetCount(sources); ++i) {
        CFDictionaryRef source = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, i));
        if (!source) continue;
        CFTypeRef type = CFDictionaryGetValue(source, CFSTR(kIOPSTypeKey));
        if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
        CFNumberRef current = (CFNumberRef)CFDictionaryGetValue(source, CFSTR(kIOPSCurrentCapacityKey));
        CFNumberRef maximum = (CFNumberRef)CFDictionaryGetValue(source, CFSTR(kIOPSMaxCapacityKey));
        int current_value = 0, max_value = 0;
        if (current) CFNumberGetValue(current, kCFNumberIntType, &current_value);
        if (maximum) CFNumberGetValue(maximum, kCFNumberIntType, &max_value);
        result->available = max_value > 0;
        result->percent = max_value > 0 ? 100.0 * current_value / max_value : 0;
        CFTypeRef charging = CFDictionaryGetValue(source, CFSTR(kIOPSIsChargingKey));
        result->charging = charging && CFEqual(charging, kCFBooleanTrue);
        CFTypeRef state = CFDictionaryGetValue(source, CFSTR(kIOPSPowerSourceStateKey));
        result->on_battery = state && CFEqual(state, CFSTR(kIOPSBatteryPowerValue));
        break;
    }
    CFRelease(sources);
    CFRelease(blob);
    if (result->available) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
        if (service) {
            CFTypeRef current = IORegistryEntryCreateCFProperty(service, CFSTR("InstantAmperage"), kCFAllocatorDefault, 0);
            CFTypeRef voltage = IORegistryEntryCreateCFProperty(service, CFSTR("Voltage"), kCFAllocatorDefault, 0);
            int64_t milliamps = 0, millivolts = 0;
            if (current && voltage && CFGetTypeID(current) == CFNumberGetTypeID()
                && CFGetTypeID(voltage) == CFNumberGetTypeID()
                && CFNumberGetValue((CFNumberRef)current, kCFNumberSInt64Type, &milliamps)
                && CFNumberGetValue((CFNumberRef)voltage, kCFNumberSInt64Type, &millivolts)
                && milliamps > -50000 && milliamps < 50000 && millivolts > 5000 && millivolts < 30000) {
                result->power_available = 1;
                result->power_watts = (double)milliamps * (double)millivolts / 1000000.0;
            }
            if (current) CFRelease(current);
            if (voltage) CFRelease(voltage);
            IOObjectRelease(service);
        }
        if (!result->on_battery) {
            CFDictionaryRef adapter = IOPSCopyExternalPowerAdapterDetails();
            if (adapter) {
                CFTypeRef value = CFDictionaryGetValue(adapter, CFSTR(kIOPSPowerAdapterWattsKey));
                if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result->adapter_watts);
                }
                CFRelease(adapter);
            }
        }
    }
    return result->available;
}

int32_t ms_performance_level_count(void) {
    int levels = 0;
    size_t size = sizeof(levels);
    return sysctlbyname("hw.nperflevels", &levels, &size, NULL, 0) == 0 ? levels : 0;
}

int32_t ms_performance_level(int32_t index, char *name, int32_t name_capacity) {
    if (!name || name_capacity <= 0 || index < 0) return 0;
    char key[64];
    snprintf(key, sizeof(key), "hw.perflevel%d.logicalcpu", index);
    int cores = 0;
    size_t size = sizeof(cores);
    if (sysctlbyname(key, &cores, &size, NULL, 0) != 0) return 0;
    snprintf(key, sizeof(key), "hw.perflevel%d.name", index);
    size = (size_t)name_capacity;
    if (sysctlbyname(key, name, &size, NULL, 0) != 0) snprintf(name, (size_t)name_capacity, "Nível %d", index + 1);
    name[name_capacity - 1] = '\0';
    return cores;
}
