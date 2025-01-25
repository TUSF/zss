# zss
zss is a [CSS](https://www.w3.org/Style/CSS/) layout engine and document renderer, written in [Zig](https://ziglang.org/).

# Building zss
To build zss, simply run `zig build --help` to see your options.

zss uses unstable (master) versions of Zig. The most recently tested compiler version is 0.14.0-dev.2316+68b3f5086.

# Standards Implemented
In general, zss tries to implement the standards contained in [CSS Snapshot 2023](https://www.w3.org/TR/css-2023/).

| Module | Level | Progress |
| ------ | ----- | ----- |
| CSS Level 2 | 2.2 | Partial |
| Syntax | 3 | Partial |
| Selectors | 3 | Partial |
| Cascading and Inheritance | 4 | Partial |
| Backgrounds and Borders | 3 | Partial |
| Values and Units | 3 | Partial |
| Namespaces | 3 | Partial |

# License
See [LICENSE.md](LICENSE.md) for detailed licensing information.
