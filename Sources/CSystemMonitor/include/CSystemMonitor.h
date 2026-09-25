#ifndef CSystemMonitor_h
#define CSystemMonitor_h

#include <stdint.h>

typedef struct {
    int32_t pid;
    uint64_t start_time;
    double cpu_seconds;
    double performance_cpu_seconds;
    uint64_t physical_bytes;
    uint64_t read_bytes;
    uint64_t written_bytes;
    double cpu_energy_joules;
    int32_t has_performance_time;
    int32_t has_energy;
    char path[4096];
} MSProcessSample;

typedef struct {
    uint64_t busy_ticks;
    uint64_t total_ticks;
    uint64_t physical_bytes;
    uint64_t used_bytes;
} MSSystemSample;

typedef struct {
    int32_t available;
    int32_t charging;
    int32_t on_battery;
    double percent;
} MSBatterySample;

typedef struct {
    char identifier[64];
    double celsius;
    int32_t source; /* 1 = SMC, 2 = HID, 3 = bateria */
} MSTemperatureSample;

int32_t ms_list_pids(int32_t *buffer, int32_t capacity);
int32_t ms_read_process(int32_t pid, MSProcessSample *result);
int32_t ms_read_system(MSSystemSample *result);
int32_t ms_read_battery(MSBatterySample *result);
int32_t ms_performance_level_count(void);
int32_t ms_performance_level(int32_t index, char *name, int32_t name_capacity);
int32_t ms_read_temperatures(MSTemperatureSample *buffer, int32_t capacity);

#endif
