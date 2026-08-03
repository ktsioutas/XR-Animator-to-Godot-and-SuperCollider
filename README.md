## XR-Aninator-to-Godot-and-SuperCollider
### General Instructions

#### SuperCollider to Godot OSCGroups Configuration
##### laptop sc-sender
`OscGroupClient.exe 165.22.82.70 22242 22346 22344 22345 kostasSC 12345 scDanceGroup test123`

##### desktop godot receiver
`OscGroupClient.exe 165.22.82.70 22242 22446 22444 22245 godotSC 12345 scDanceGroup test123`


##### XR-Animator to Godot OSCGroups Configuration
###### XR-Animator laptop sender
`OscGroupClient.exe 165.22.82.70 22242 22246 22244 22245 kostasLaptop 12345 skeletonTest test123`

###### desktop Godot receiver
`OscGroupClient.exe 165.22.82.70 22242 22246 22244 39539 kostasDesktop 12345 skeletonTest test123`

#### Ianis in SuperCollider
##### Receive from XR Animator /rokoko format data additional OSGroup Command
`OscGroupClient.exe 165.22.82.70 22242 22546 22544 57130 iannisVMC 12345 skeletonTest test123`


### For a 3 machine setup

##### XR Animator laptop — one command

`OscGroupClient.exe 165.22.82.70 22242 22246 22244 22245 kostasLaptop 12345 skeletonTest test123`


##### Iannis’s Mac — two commands
###### Terminal 1: receive XR Animator VMC
`./OscGroupClient 165.22.82.70 22242 22546 22544 57130 iannisVMC 12345 skeletonTest test123`

###### Terminal 2: send SuperCollider/sc-dance to Godot
`./OscGroupClient 165.22.82.70 22242 22346 22344 22345 iannisSC 12345 scDanceGroup test123`


##### Godot desktop — two commands

###### Command Prompt 1: receive XR Animator VMC

`OscGroupClient.exe 165.22.82.70 22242 22246 22244 39539 kostasDesktop 12345 skeletonTest test123`

###### Command Prompt 2: receive SuperCollider/sc-dance

`OscGroupClient.exe 165.22.82.70 22242 22446 22444 22245 godotSC 12345 scDanceGroup test123`






#### OSCGroups network architecture

```mermaid
flowchart LR
    subgraph LAPTOP["XR Animator + SuperCollider laptop — 3 OSCGroups clients"]
        XR["XR Animator<br/>VMC → 127.0.0.1:39538"]
        PY["Python packet splitter<br/>39538 → 22244"]
        L1["L1: kostasLaptop<br/>skeletonTest<br/>VMC sender"]
        L2["L2: iannisVMC<br/>skeletonTest<br/>output → SC 57130"]
        SC["SuperCollider<br/>VMC → music /rokoko/"]
        L3["L3: kostasSC<br/>scDanceGroup<br/>SC input 22344"]

        XR --> PY --> L1
        L2 --> SC
        SC -. "optional sc-dance output → 22344" .-> L3
    end

    subgraph SERVER["OSCGroups server — 165.22.82.70:22242"]
        G1["skeletonTest<br/>XR Animator VMC"]
        G2["scDanceGroup<br/>SuperCollider Rokoko"]
    end

    subgraph DESKTOP["Remote Godot desktop — 2 OSCGroups clients"]
        D1["D1: kostasDesktop<br/>skeletonTest<br/>output → 39539"]
        VMC["Godot VMC tracker<br/>/vmc/body_tracker"]

        D2["D2: godotSC<br/>scDanceGroup<br/>output → 22245"]
        ROK["Godot SC tracker<br/>/sc/rokoko/body_tracker"]

        MIX["Tracker mixer<br/>/merged/body_tracker"]
        AV["Godot avatar"]

        D1 --> VMC --> MIX
        D2 --> ROK --> MIX
        MIX --> AV
    end

    L1 --> G1
    G1 --> D1
    G1 --> L2

    L3 --> G2
    G2 --> D2
```
