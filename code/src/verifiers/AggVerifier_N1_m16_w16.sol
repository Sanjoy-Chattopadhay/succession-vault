// SPDX-License-Identifier: GPL-3.0
/*
    Copyright 2021 0KIMS association.

    This file is generated with [snarkJS](https://github.com/iden3/snarkjs).

    snarkJS is a free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    snarkJS is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
    License for more details.

    You should have received a copy of the GNU General Public License
    along with snarkJS. If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity ^0.8.24;

contract AggVerifier_N1_m16_w16 {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data
    uint256 constant alphax  = 16428432848801857252194528405604668803277877773566238944394625302971855135431;
    uint256 constant alphay  = 16846502678714586896801519656441059708016666274385668027902869494772365009666;
    uint256 constant betax1  = 3182164110458002340215786955198810119980427837186618912744689678939861918171;
    uint256 constant betax2  = 16348171800823588416173124589066524623406261996681292662100840445103873053252;
    uint256 constant betay1  = 4920802715848186258981584729175884379674325733638798907835771393452862684714;
    uint256 constant betay2  = 19687132236965066906216944365591810874384658708175106803089633851114028275753;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant deltax1 = 1558734965837282294723377656226871546261169763913027313479200438676218012357;
    uint256 constant deltax2 = 20824956765162291245561622058712118191212941296385938199504817545531642386242;
    uint256 constant deltay1 = 770736972111410223562231713791640786243126031299147508407898390207484495215;
    uint256 constant deltay2 = 5398418761736448899364434436519141943487197580937369668868407285230435408518;

    
    uint256 constant IC0x = 13665608178221485539047258875261666062758570708555428474170394941490541667058;
    uint256 constant IC0y = 21616027155707883321547545696394477384551902090551342798392974268370541725222;
    
    uint256 constant IC1x = 213430334033313086046737258650906690036335591846108798096154745784466543907;
    uint256 constant IC1y = 6954978560351321756142889274537385310095158189380999064904030049200503679000;
    
    uint256 constant IC2x = 3755554213365679625344971694272343255935725329009393183686940342452513497898;
    uint256 constant IC2y = 13699187364337212340121680653131943065260405646738328636261982416442225142176;
    
    uint256 constant IC3x = 5861860104637953100877559219182190352349722859583950565788188349459323777260;
    uint256 constant IC3y = 3637422756244595118766550947008212888663092333550797996801815820674967345415;
    
    uint256 constant IC4x = 7563873396873379889917850460861547752429259948623600614461421627997438054757;
    uint256 constant IC4y = 20657011369329338145571013859275348532519170873682022573537203141554406833227;
    
    uint256 constant IC5x = 13925960343709731191129809376013440254511645599441681943854777168810798013146;
    uint256 constant IC5y = 10040114670616074497344138942757201283667640173162129792004085488121311708817;
    
    uint256 constant IC6x = 21144691010170398450981186805221730751767455612366213041494533146678877092055;
    uint256 constant IC6y = 4398208664140430487597645217747017174984748853606397571943351030314686587813;
    
    uint256 constant IC7x = 12842865552489613062536953667427599668728092747373218645144089556160365931529;
    uint256 constant IC7y = 6677705939819673213398258696579966765304773635802949971468023918962237963702;
    
    uint256 constant IC8x = 12096625194088568179628160315795751888621200561448609723268659448656416262513;
    uint256 constant IC8y = 9464603585087262184642684841277638462437251122320781189294853337417998671999;
    
    uint256 constant IC9x = 7977384130993495235043633465215105549534277474483547682721604759128088075781;
    uint256 constant IC9y = 5140776001008091988650664048951516607314992627454025461808148292953043947079;
    
    uint256 constant IC10x = 1529043559743958303886420884001925046214594476001099826683301988780043525269;
    uint256 constant IC10y = 13870326698177964797276156315060999560938340370687724151218215908073115248976;
    
    uint256 constant IC11x = 5014479223580211823646540807968690056071142487914242157903646515068269660396;
    uint256 constant IC11y = 14080232278661527246268545172468300242923311463041019245171876270004469400305;
    
    uint256 constant IC12x = 2491056685648118431371737506715675608009220655916308930688035247654019570709;
    uint256 constant IC12y = 524924038338872797978329093069163152154236618155846524429369504798986066239;
    
    uint256 constant IC13x = 118985267144682277321838331996230411560491035649943694590334971107021884870;
    uint256 constant IC13y = 14838410425473237746183305098354074334952967575559788700261832346439386732697;
    
    uint256 constant IC14x = 19824813358593656280647647232313856962430431208921066197972482609409913326164;
    uint256 constant IC14y = 13206440032323209419410953669896989925243270080803630952554458233079550965901;
    
    uint256 constant IC15x = 3903812509973668782075021986591130746255313113337037102900290080888848732694;
    uint256 constant IC15y = 17777191329035039497084879963253554515514010939853462246458377275320680205508;
    
    uint256 constant IC16x = 16562255894838745061786476742757385406710400765772730511668702245892102405064;
    uint256 constant IC16y = 5982490900739661651162064620233678166739730427065791452311717369509255317552;
    
    uint256 constant IC17x = 11105886234629667087623372986625858328539971006185176376503327899211186752064;
    uint256 constant IC17y = 20252955103464121818430892985175503735198522656391339959579192326868556544818;
    
    uint256 constant IC18x = 16157605270327449934997297450746097022763854856290563220394246639110638705433;
    uint256 constant IC18y = 2659764508500960119033946243375483952345150794168619823526107585386318373364;
    
    uint256 constant IC19x = 2544550064130455384888874192714031771732148774037033278601811596950811099781;
    uint256 constant IC19y = 17894910366502200071506907412705655255199597961905904045822919734643098817833;
    
    uint256 constant IC20x = 9294283624294662470590006205629549963256410277195484893019792243531819359393;
    uint256 constant IC20y = 9426851197307864338082041846681945714644724003346864158063784906220027532282;
    
 
    // Memory data
    uint16 constant pVk = 0;
    uint16 constant pPairing = 128;

    uint16 constant pLastMem = 896;

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[20] calldata _pubSignals) public view returns (bool) {
        assembly {
            function checkField(v) {
                if iszero(lt(v, r)) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }
            
            // G1 function to multiply a G1 value(x,y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            function checkPairing(pA, pB, pC, pubSignals, pMem) -> isOk {
                let _pPairing := add(pMem, pPairing)
                let _pVk := add(pMem, pVk)

                mstore(_pVk, IC0x)
                mstore(add(_pVk, 32), IC0y)

                // Compute the linear combination vk_x
                
                g1_mulAccC(_pVk, IC1x, IC1y, calldataload(add(pubSignals, 0)))
                
                g1_mulAccC(_pVk, IC2x, IC2y, calldataload(add(pubSignals, 32)))
                
                g1_mulAccC(_pVk, IC3x, IC3y, calldataload(add(pubSignals, 64)))
                
                g1_mulAccC(_pVk, IC4x, IC4y, calldataload(add(pubSignals, 96)))
                
                g1_mulAccC(_pVk, IC5x, IC5y, calldataload(add(pubSignals, 128)))
                
                g1_mulAccC(_pVk, IC6x, IC6y, calldataload(add(pubSignals, 160)))
                
                g1_mulAccC(_pVk, IC7x, IC7y, calldataload(add(pubSignals, 192)))
                
                g1_mulAccC(_pVk, IC8x, IC8y, calldataload(add(pubSignals, 224)))
                
                g1_mulAccC(_pVk, IC9x, IC9y, calldataload(add(pubSignals, 256)))
                
                g1_mulAccC(_pVk, IC10x, IC10y, calldataload(add(pubSignals, 288)))
                
                g1_mulAccC(_pVk, IC11x, IC11y, calldataload(add(pubSignals, 320)))
                
                g1_mulAccC(_pVk, IC12x, IC12y, calldataload(add(pubSignals, 352)))
                
                g1_mulAccC(_pVk, IC13x, IC13y, calldataload(add(pubSignals, 384)))
                
                g1_mulAccC(_pVk, IC14x, IC14y, calldataload(add(pubSignals, 416)))
                
                g1_mulAccC(_pVk, IC15x, IC15y, calldataload(add(pubSignals, 448)))
                
                g1_mulAccC(_pVk, IC16x, IC16y, calldataload(add(pubSignals, 480)))
                
                g1_mulAccC(_pVk, IC17x, IC17y, calldataload(add(pubSignals, 512)))
                
                g1_mulAccC(_pVk, IC18x, IC18y, calldataload(add(pubSignals, 544)))
                
                g1_mulAccC(_pVk, IC19x, IC19y, calldataload(add(pubSignals, 576)))
                
                g1_mulAccC(_pVk, IC20x, IC20y, calldataload(add(pubSignals, 608)))
                

                // -A
                mstore(_pPairing, calldataload(pA))
                mstore(add(_pPairing, 32), mod(sub(q, calldataload(add(pA, 32))), q))

                // B
                mstore(add(_pPairing, 64), calldataload(pB))
                mstore(add(_pPairing, 96), calldataload(add(pB, 32)))
                mstore(add(_pPairing, 128), calldataload(add(pB, 64)))
                mstore(add(_pPairing, 160), calldataload(add(pB, 96)))

                // alpha1
                mstore(add(_pPairing, 192), alphax)
                mstore(add(_pPairing, 224), alphay)

                // beta2
                mstore(add(_pPairing, 256), betax1)
                mstore(add(_pPairing, 288), betax2)
                mstore(add(_pPairing, 320), betay1)
                mstore(add(_pPairing, 352), betay2)

                // vk_x
                mstore(add(_pPairing, 384), mload(add(pMem, pVk)))
                mstore(add(_pPairing, 416), mload(add(pMem, add(pVk, 32))))


                // gamma2
                mstore(add(_pPairing, 448), gammax1)
                mstore(add(_pPairing, 480), gammax2)
                mstore(add(_pPairing, 512), gammay1)
                mstore(add(_pPairing, 544), gammay2)

                // C
                mstore(add(_pPairing, 576), calldataload(pC))
                mstore(add(_pPairing, 608), calldataload(add(pC, 32)))

                // delta2
                mstore(add(_pPairing, 640), deltax1)
                mstore(add(_pPairing, 672), deltax2)
                mstore(add(_pPairing, 704), deltay1)
                mstore(add(_pPairing, 736), deltay2)


                let success := staticcall(sub(gas(), 2000), 8, _pPairing, 768, _pPairing, 0x20)

                isOk := and(success, mload(_pPairing))
            }

            let pMem := mload(0x40)
            mstore(0x40, add(pMem, pLastMem))

            // Validate that all evaluations ∈ F
            
            checkField(calldataload(add(_pubSignals, 0)))
            
            checkField(calldataload(add(_pubSignals, 32)))
            
            checkField(calldataload(add(_pubSignals, 64)))
            
            checkField(calldataload(add(_pubSignals, 96)))
            
            checkField(calldataload(add(_pubSignals, 128)))
            
            checkField(calldataload(add(_pubSignals, 160)))
            
            checkField(calldataload(add(_pubSignals, 192)))
            
            checkField(calldataload(add(_pubSignals, 224)))
            
            checkField(calldataload(add(_pubSignals, 256)))
            
            checkField(calldataload(add(_pubSignals, 288)))
            
            checkField(calldataload(add(_pubSignals, 320)))
            
            checkField(calldataload(add(_pubSignals, 352)))
            
            checkField(calldataload(add(_pubSignals, 384)))
            
            checkField(calldataload(add(_pubSignals, 416)))
            
            checkField(calldataload(add(_pubSignals, 448)))
            
            checkField(calldataload(add(_pubSignals, 480)))
            
            checkField(calldataload(add(_pubSignals, 512)))
            
            checkField(calldataload(add(_pubSignals, 544)))
            
            checkField(calldataload(add(_pubSignals, 576)))
            
            checkField(calldataload(add(_pubSignals, 608)))
            

            // Validate all evaluations
            let isValid := checkPairing(_pA, _pB, _pC, _pubSignals, pMem)

            mstore(0, isValid)
             return(0, 0x20)
         }
     }
 }
