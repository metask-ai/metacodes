#include <math.h>

struct Point {
    int x;
    int y;
};

enum Color { RED, GREEN, BLUE };

typedef struct Point PointT;

double distance(struct Point a, struct Point b) {
    int dx = a.x - b.x;
    int dy = a.y - b.y;
    return sqrt((double)(dx * dx + dy * dy));
}
