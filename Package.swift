// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "HFSKit",
    products: [
        // This is what your app will depend on
        .library(name: "HFSKit", targets: ["HFSKit"])
    ],
    targets: [
        // C target: libhfs + copyin/copyout + your wrapper
        .target(
            name: "HFSCore",
            path: "Sources/HFSCore",
            exclude: [
                "libhfs/os.c",
                "hfsck/main.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("libhfs"),
                .headerSearchPath("hfsutils"),
                .headerSearchPath("hfsck")
                // add more if needed
            ]
        ),
        // Swift target: your friendly API
        .target(
            name: "HFSKit",
            dependencies: ["HFSCore"],
            path: "Sources/HFSKit",
            swiftSettings: [
                .define("NEW_COPY")
            ]
        ),
        .testTarget(
            name: "HFSKitTests",
            dependencies: ["HFSKit", "HFSCore"],
            resources: [
                    .copy("Resources/test.img"),
                    .copy("Resources/test2.img"),
                    .copy("Resources/mountain"),
                    .copy("Resources/sunglasses.bin"),
                    .copy("Resources/multi.hda"),
                    .copy("Resources/binhex_sample.hqx"),
                    .copy("Resources/macbinary_sample.smi_.bin"),
                    .copy("Resources/text_sample.txt")
                ]
        )
    ]
)
